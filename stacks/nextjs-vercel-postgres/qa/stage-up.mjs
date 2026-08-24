// TEMPLATE: stage-up: staging on demand. Adjust the ADJUST-marked consts.
//
// Creates a Neon branch off prod (copy-on-write snapshot of live data),
// deploys the CURRENT WORKING TREE as a Vercel preview deployment wired to
// that branch, aliases it to a stable staging URL, and smoke-checks it.
//
// Usage (wire as package.json scripts stage:up / stage:down):
//   pnpm stage:up                 branch + deploy + alias + smoke
//   pnpm stage:up --migrate       also run pending migrations against the
//                                 BRANCH before deploying (rehearse a prod
//                                 migration on prod-shaped data, safely)
//   pnpm stage:up --branch-only   create the DB branch, skip the deploy
//                                 (for pointing local dev at a safe copy)
//   pnpm stage:up --alias <host>  override the staging alias
//
// Re-run safety: every run creates a NEW branch and re-points the alias.
// Old branches accumulate until `pnpm stage:down --apply` deletes them.
//
// Safety bounds:
//   - Never touches the prod branch: branching is copy-on-write and this
//     script only ever CREATES branches.
//   - Migrations run against the new branch only (direct, unpooled URL).
//   - The deploy is a preview deployment: Vercel crons never fire on it.
//
// Caveats to document for YOUR app (printed in the summary; edit to fit):
//   - OAuth/API tokens inside the branched data are REAL. Anything the
//     staged app sends or calls externally is a real send or call.
//   - Shared stores (blob storage, redis) are usually NOT branched.
//     Deleting a file on staging may delete the real blob.
//   - Vercel preview deployments sit behind SSO. Open the URL in a
//     browser where you are logged into Vercel.

import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import {
  REPO_ROOT,
  STAGE_BRANCH_PREFIX,
  listBranches,
  neonApi,
  redactDbUrl,
  resolveNeonCredentials,
  selectStageBranches,
} from "./stage-shared.mjs";

// ADJUST: a stable *.vercel.app alias for staging. NEXT_PUBLIC_APP_URL is
// baked to this at build time so auth trusted-origins line up.
const DEFAULT_ALIAS = process.env.STAGE_ALIAS || "your-app-staging.vercel.app";
// ADJUST: a table to count as proof the branch carries real data (your tenant table).
const SANITY_TABLE = process.env.STAGE_SANITY_TABLE || "tenants";
// ADJUST: how to run migrations and where the postgres package resolves.
const WEB_DIR = ["apps", "web"];
const MIGRATE_ARGS = ["--filter", "<your-web-package>", "exec", "drizzle-kit", "migrate"];

function parseArgs(argv) {
  const args = { migrate: false, branchOnly: false, alias: DEFAULT_ALIAS };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--migrate") args.migrate = true;
    else if (a === "--branch-only") args.branchOnly = true;
    else if (a === "--alias") args.alias = argv[++i];
    else {
      console.error(`[stage-up] unknown arg: ${a}`);
      process.exit(1);
    }
  }
  if (!args.alias || args.alias.includes("/")) {
    console.error("[stage-up] --alias must be a bare host, e.g. foo.vercel.app");
    process.exit(1);
  }
  return args;
}

const quote = (s) => `"${String(s).replaceAll('"', '\\"')}"`;

/** Run a command through the shell, streaming stderr, capturing stdout. */
function run(cmd, argList, { capture = false, env } = {}) {
  const full = [cmd, ...argList.map(quote)].join(" ");
  const res = spawnSync(full, {
    shell: true,
    cwd: REPO_ROOT,
    stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit",
    env: env ? { ...process.env, ...env } : process.env,
    encoding: "utf8",
  });
  if (res.status !== 0) {
    throw new Error(`command failed (exit ${res.status}): ${cmd} ${argList[0] ?? ""}...`);
  }
  return capture ? (res.stdout ?? "").trim() : "";
}

function gitShortSha() {
  try {
    return run("git", ["rev-parse", "--short", "HEAD"], { capture: true });
  } catch {
    return "nogit";
  }
}

function timestampSlug() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

/** Fetch pooled + direct connection URIs for a branch. */
async function connectionUris(apiKey, projectId, branchId) {
  const dbs = await neonApi(
    apiKey,
    "GET",
    `/projects/${projectId}/branches/${branchId}/databases`,
  );
  const db = dbs.databases?.[0];
  if (!db) throw new Error("new branch has no databases (unexpected)");
  const q = (pooled) =>
    `/projects/${projectId}/connection_uri?branch_id=${branchId}` +
    `&database_name=${encodeURIComponent(db.name)}` +
    `&role_name=${encodeURIComponent(db.owner_name)}&pooled=${pooled}`;
  const [pooled, direct] = await Promise.all([
    neonApi(apiKey, "GET", q("true")),
    neonApi(apiKey, "GET", q("false")),
  ]);
  const withSsl = (uri) => (uri.includes("sslmode=") ? uri : `${uri}?sslmode=require`);
  return { pooled: withSsl(pooled.uri), direct: withSsl(direct.uri) };
}

/** Connect to the branch and count tenant rows. Proves the copy is real. */
async function sanityCheckBranch(directUri) {
  let postgres;
  try {
    const req = createRequire(path.join(REPO_ROOT, ...WEB_DIR, "package.json"));
    postgres = req("postgres");
  } catch {
    console.warn("[stage-up] postgres package not resolvable; skipping DB sanity check");
    return;
  }
  const sql = postgres(directUri, { max: 1, connect_timeout: 30 });
  try {
    const [row] = await sql.unsafe(`select count(*)::int as n from "` + SANITY_TABLE + `"`);
    console.log(`[stage-up] branch sanity: ${row.n} ${SANITY_TABLE} rows visible on the branch`);
  } finally {
    await sql.end({ timeout: 5 });
  }
}

async function smokeCheck(aliasUrl) {
  try {
    const res = await fetch(`${aliasUrl}/api/health`, { redirect: "manual" });
    if (res.status === 200) {
      console.log("[stage-up] smoke: /api/health 200 OK");
      return;
    }
    if (res.status === 401 || (res.status >= 300 && res.status < 400)) {
      console.log(
        `[stage-up] smoke: /api/health ${res.status} (Vercel SSO deployment protection). ` +
          "Expected. Open the URL in a browser where you are logged into Vercel.",
      );
      return;
    }
    console.warn(`[stage-up] smoke: /api/health unexpected status ${res.status}`);
  } catch (err) {
    console.warn(`[stage-up] smoke: fetch failed: ${err.message}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { apiKey, projectId } = resolveNeonCredentials();

  const existing = selectStageBranches(await listBranches(apiKey, projectId));
  if (existing.length >= 3) {
    console.warn(
      `[stage-up] ${existing.length} stage branches already exist. ` +
        "Run `pnpm stage:down --apply` to clean up (branches cost storage).",
    );
  }

  const branchName = `${STAGE_BRANCH_PREFIX}${timestampSlug()}-${gitShortSha()}`;
  console.log(`[stage-up] creating Neon branch ${branchName} off prod...`);
  const created = await neonApi(apiKey, "POST", `/projects/${projectId}/branches`, {
    branch: { name: branchName },
    endpoints: [{ type: "read_write" }],
  });
  const branchId = created.branch?.id;
  if (!branchId) throw new Error("branch create returned no id");
  console.log(`[stage-up] branch created: ${branchId}`);

  const { pooled, direct } = await connectionUris(apiKey, projectId, branchId);
  console.log(`[stage-up] pooled connection: ${redactDbUrl(pooled)}`);
  await sanityCheckBranch(direct);

  if (args.migrate) {
    console.log("[stage-up] running Drizzle migrations against the BRANCH...");
    run("pnpm", MIGRATE_ARGS, {
      env: { DATABASE_URL: direct },
    });
    console.log("[stage-up] migrations applied to the branch");
  }

  if (args.branchOnly) {
    console.log("\n[stage-up] --branch-only: skipping deploy.");
    console.log(`[stage-up] branch:   ${branchName}`);
    console.log(`[stage-up] host:     ${new URL(pooled).host}`);
    console.log("[stage-up] Point DATABASE_URL at this branch to use it locally.");
    console.log("[stage-up] Tear down later with: pnpm stage:down --apply");
    return;
  }

  const aliasUrl = `https://${args.alias}`;
  console.log("[stage-up] deploying working tree to a Vercel preview deployment...");
  const deployUrl = run(
    "vercel",
    [
      "deploy",
      "--yes",
      ...["-e", `DATABASE_URL=${pooled}`, "-b", `DATABASE_URL=${pooled}`],
      ...["-e", `DATABASE_URL_UNPOOLED=${direct}`, "-b", `DATABASE_URL_UNPOOLED=${direct}`],
      ...["-e", `NEXT_PUBLIC_APP_URL=${aliasUrl}`, "-b", `NEXT_PUBLIC_APP_URL=${aliasUrl}`],
    ],
    { capture: true },
  );
  if (!deployUrl.startsWith("https://")) {
    throw new Error(`vercel deploy did not return a URL (got: ${deployUrl.slice(0, 200)})`);
  }
  console.log(`[stage-up] deployed: ${deployUrl}`);

  console.log(`[stage-up] aliasing to ${args.alias}...`);
  try {
    run("vercel", ["alias", "set", deployUrl, args.alias]);
  } catch (err) {
    console.error(
      `[stage-up] ALIAS FAILED: ${err.message}\n` +
        "[stage-up] Auth (Better Auth trusted origins) is built for the alias URL, so " +
        "logins on the raw deployment URL will 403. Re-run with --alias <other-host> " +
        "if the default alias is taken.",
    );
    process.exitCode = 1;
    return;
  }

  await smokeCheck(aliasUrl);

  console.log(`
[stage-up] STAGING IS UP
  url:        ${aliasUrl}  (Vercel SSO protected; open in your browser)
  db branch:  ${branchName}  (copy-on-write snapshot of prod, isolated)
  deploy:     ${deployUrl}

  Crons never fire on preview deployments. Whatever your Preview env
  lacks (error reporting, OAuth secrets) is off here by design.

  CAREFUL, the usual live wires (adjust for your app):
  1. Tokens inside the branched data are REAL; sends from staging are
     real sends.
  2. Shared stores (blob, redis) are NOT branched; deletions can hit
     real objects.

  Tear down when done: pnpm stage:down --apply
`);
}

main().catch((err) => {
  console.error(`[stage-up] FAILED: ${err.message}`);
  process.exit(1);
});
