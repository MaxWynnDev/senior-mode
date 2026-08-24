// TEMPLATE: shared helpers for the staging-on-demand scripts
// (stage-up / stage-down). Copy all three stage-*.mjs into your repo's
// scripts/ dir. Assumes a Postgres host with copy-on-write branching and
// a REST API (Neon by default; swap neonApi for your provider).
//
// Auth model: Neon REST API via NEON_API_KEY, read from the process env
// or your env file. NEON_PROJECT_ID comes from the same places.
//
// Nothing in here mutates anything by itself; the callers decide.

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

// ADJUST: where NEON_API_KEY / NEON_PROJECT_ID live.
const ENV_FILE_CANDIDATES = [
  path.join(REPO_ROOT, ".env.local"),
  path.join(REPO_ROOT, "apps", "web", ".env.local"),
];

export const STAGE_BRANCH_PREFIX = "stage/";
export const NEON_API_BASE = "https://console.neon.tech/api/v2";

/** Parse a dotenv file into a plain object. */
function parseEnvFile(filePath) {
  const out = {};
  let text;
  try {
    text = readFileSync(filePath, "utf8");
  } catch {
    return out;
  }
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

/**
 * Resolve NEON_API_KEY + NEON_PROJECT_ID. Process env wins; falls back to
 * apps/web/.env.local. Exits with setup instructions when the key is absent
 * so the operator never sees a bare 401.
 */
export function resolveNeonCredentials() {
  const envPath = ENV_FILE_CANDIDATES.find((p) => existsSync(p));
  const envFile = envPath ? parseEnvFile(envPath) : {};
  const apiKey = process.env.NEON_API_KEY || envFile.NEON_API_KEY;
  const projectId = process.env.NEON_PROJECT_ID || envFile.NEON_PROJECT_ID;

  if (!projectId) {
    console.error(
      "[stage] NEON_PROJECT_ID not found in the environment or apps/web/.env.local.\n" +
        "[stage] Run `vercel env pull` (or your equivalent) to restore it.",
    );
    process.exit(1);
  }
  if (!apiKey) {
    console.error(
      "[stage] NEON_API_KEY is not set (checked process env and apps/web/.env.local).\n" +
        "[stage] One-time setup:\n" +
        "[stage]   1. https://console.neon.tech -> Account settings -> API keys -> Create new key\n" +
        "[stage]   2. Add NEON_API_KEY=<key> to your gitignored env file\n" +
        "[stage] Then re-run this command.",
    );
    process.exit(1);
  }
  return { apiKey, projectId };
}

/** Minimal Neon API client. Throws with the API's error message on non-2xx. */
export async function neonApi(apiKey, method, pathname, body) {
  const res = await fetch(`${NEON_API_BASE}${pathname}`, {
    method,
    headers: {
      Authorization: `Bearer ${apiKey}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  if (!res.ok) {
    const detail = json?.message || json?.error || text || res.statusText;
    throw new Error(`Neon API ${method} ${pathname} -> ${res.status}: ${detail}`);
  }
  return json;
}

/** List branches for the project. */
export async function listBranches(apiKey, projectId) {
  const json = await neonApi(apiKey, "GET", `/projects/${projectId}/branches`);
  return json.branches ?? [];
}

/** Stage branches only: our prefix, never the default or a protected branch. */
export function selectStageBranches(branches) {
  return branches.filter(
    (b) =>
      b.name?.startsWith(STAGE_BRANCH_PREFIX) && !b.default && !b.protected,
  );
}

/** Redact the password section of a postgres URL for safe logging. */
export function redactDbUrl(url) {
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.username}:***@${u.host}${u.pathname}`;
  } catch {
    return "<unparseable-url>";
  }
}
