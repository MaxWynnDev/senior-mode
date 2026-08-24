// stage-down: tear down staging Neon branches created by stage-up.
//
// DRY-RUN BY DEFAULT. Lists matching branches and exits. Nothing is
// deleted until you pass --apply.
//
// Usage:
//   pnpm stage:down                      list stage/* branches (dry run)
//   pnpm stage:down --apply              delete ALL stage/* branches
//   pnpm stage:down --apply --branch stage/20260612-1430-8da51e0
//                                        delete one specific branch
//
// Safety bounds:
//   - Only branches whose name starts with "stage/" are ever considered.
//   - The default (prod) branch and protected branches are excluded even
//     if someone renames one to start with "stage/".
//   - The Vercel preview deployment is left alone: with its DB branch
//     gone it just errors, and the next stage-up re-points the alias.

import {
  STAGE_BRANCH_PREFIX,
  listBranches,
  neonApi,
  resolveNeonCredentials,
  selectStageBranches,
} from "./stage-shared.mjs";

function parseArgs(argv) {
  const args = { apply: false, branch: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") args.apply = true;
    else if (a === "--branch") args.branch = argv[++i];
    else {
      console.error(`[stage-down] unknown arg: ${a}`);
      process.exit(1);
    }
  }
  if (args.branch && !args.branch.startsWith(STAGE_BRANCH_PREFIX)) {
    console.error(
      `[stage-down] refusing: --branch must start with "${STAGE_BRANCH_PREFIX}" ` +
        "(this script only manages staging branches)",
    );
    process.exit(1);
  }
  return args;
}

function ageDays(createdAt) {
  const ms = Date.now() - new Date(createdAt).getTime();
  return Math.max(0, Math.round(ms / 86_400_000));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { apiKey, projectId } = resolveNeonCredentials();

  let targets = selectStageBranches(await listBranches(apiKey, projectId));
  if (args.branch) {
    targets = targets.filter((b) => b.name === args.branch);
    if (targets.length === 0) {
      console.error(`[stage-down] no stage branch named ${args.branch} found`);
      process.exit(1);
    }
  }

  if (targets.length === 0) {
    console.log("[stage-down] no stage branches exist. Nothing to do.");
    return;
  }

  console.log(`[stage-down] ${targets.length} stage branch(es):`);
  for (const b of targets) {
    console.log(`  ${b.name}  (id ${b.id}, created ${ageDays(b.created_at)}d ago)`);
  }

  if (!args.apply) {
    console.log("\n[stage-down] dry run. Re-run with --apply to delete the above.");
    return;
  }

  for (const b of targets) {
    console.log(`[stage-down] deleting ${b.name}...`);
    await neonApi(apiKey, "DELETE", `/projects/${projectId}/branches/${b.id}`);
    console.log(`[stage-down] deleted ${b.name}`);
  }
  console.log("[stage-down] done. The staging alias now points at a deployment with no DB; the next stage-up re-points it.");
}

main().catch((err) => {
  console.error(`[stage-down] FAILED: ${err.message}`);
  process.exit(1);
});
