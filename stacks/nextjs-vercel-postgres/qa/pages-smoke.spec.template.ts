// TEMPLATE: copy into your Playwright e2e dir (e.g. e2e/pages-smoke.spec.ts)
// and adjust the marked spots. Assumes Next.js App Router and an auth
// fixture that provides a signed-in page (see your kit's e2e auth pattern:
// sign in ONCE per run in a setup project, save storage state, load it in
// fixtures; per-test sign-ins will trip your auth rate limiter).
//
// Authed page sweep: renders every static app route and fails on server
// errors, client-side crashes, or broken data fetches.
//
// Routes are DISCOVERED from the filesystem at runtime (any directory with
// a page.tsx and no [dynamic] segment), so a change that adds a page is
// swept automatically; nobody has to remember to update a list.
//
// Failure conditions per route:
//   - final navigation response status >= 500
//   - an uncaught client-side exception (pageerror)
//   - the production error boundary ("Application error: ...")
//   - any same-origin response >= 500 while the page settles (a page that
//     renders an empty shell over a 500ing API is still a broken page)
//
// All routes are checked before asserting, so one broken page does not
// hide the rest.
//
// Also works against a DEPLOYED target: set BASE_URL to the remote URL and
// make your playwright.config skip its local webServer for non-localhost
// BASE_URLs:
//
//   const remoteTarget = !!process.env.BASE_URL &&
//     !process.env.BASE_URL.includes("localhost") &&
//     !process.env.BASE_URL.includes("127.0.0.1");
//   webServer: process.env.CI || remoteTarget ? undefined : { ... }
//
// To WATCH the sweep in a visible browser, gate headless on an env flag in
// playwright.config so the launcher can flip it (off in CI by default):
//   const headed = process.env.PWHEADED === "1" && !process.env.CI;
//   use: { headless: !headed, launchOptions: headed ? { slowMo: 350 } : {} }
import { readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { test as authedTest, expect } from "./fixtures/auth"; // ADJUST: your auth fixture

// ADJUST: where your authed route group lives.
const APP_GROUP_CANDIDATES = [
  path.join(process.cwd(), "src", "app", "(dashboard)"),
  path.join(process.cwd(), "apps", "web", "src", "app", "(dashboard)"),
];

// ADJUST: dynamic-segment routes that are stable in practice (e.g. object
// list pages whose slugs ship with every tenant). Leave empty to start.
const EXTRA_ROUTES: string[] = [];

function findAppGroupDir(): string {
  const hit = APP_GROUP_CANDIDATES.find((c) => existsSync(c));
  if (!hit) throw new Error("cannot locate the app route group from cwd");
  return hit;
}

function discoverStaticRoutes(): string[] {
  const root = findAppGroupDir();
  const routes: string[] = [];
  const walk = (dir: string, urlPath: string) => {
    const entries = readdirSync(dir, { withFileTypes: true });
    if (entries.some((e) => e.isFile() && e.name === "page.tsx")) {
      routes.push(urlPath || "/");
    }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (e.name.includes("[")) continue; // dynamic segments handled separately
      const isGroup = e.name.startsWith("(") && e.name.endsWith(")");
      walk(path.join(dir, e.name), isGroup ? urlPath : `${urlPath}/${e.name}`);
    }
  };
  walk(root, "");
  return routes.sort();
}

authedTest.describe("Page sweep (authed)", () => {
  authedTest("every static page renders without errors", async ({ authedPage: page }) => {
    authedTest.setTimeout(10 * 60_000);

    const routes = [...discoverStaticRoutes(), ...EXTRA_ROUTES];
    expect(routes.length, "route discovery returned implausibly few routes").toBeGreaterThan(5);

    let pageErrors: string[] = [];
    let serverErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));
    page.on("response", (res) => {
      if (res.status() < 500) return;
      try {
        const sameOrigin = new URL(res.url()).origin === new URL(page.url()).origin;
        if (sameOrigin) serverErrors.push(`${res.status()} ${new URL(res.url()).pathname}`);
      } catch {
        // page.url() can be about:blank between navigations; ignore
      }
    });

    const failures: string[] = [];
    for (const route of routes) {
      pageErrors = [];
      serverErrors = [];
      let status = 0;
      try {
        const res = await page.goto(route, { waitUntil: "domcontentloaded" });
        status = res?.status() ?? 0;
        await page.waitForTimeout(800); // let client fetches fire
      } catch (err) {
        failures.push(`${route}: navigation failed (${(err as Error).message})`);
        continue;
      }
      if (status >= 500) failures.push(`${route}: HTTP ${status}`);
      const boundary = await page
        .getByText("Application error: a client-side exception has occurred", { exact: false })
        .count();
      if (boundary > 0) failures.push(`${route}: production error boundary rendered`);
      if (pageErrors.length) failures.push(`${route}: pageerror ${pageErrors.join(" | ")}`);
      if (serverErrors.length) failures.push(`${route}: API ${serverErrors.join(", ")}`);
    }

    expect(failures, `broken pages:\n  ${failures.join("\n  ")}`).toEqual([]);
  });

  // ADJUST or delete: one dynamic-route example. Create a record via your
  // API, visit its detail page, assert the page's actual contract (what
  // the header really renders), and check client crashes BEFORE the
  // visibility wait so failures carry diagnostics.
});
