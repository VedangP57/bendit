#!/usr/bin/env node
// Run a scenario file against a real browser and leave evidence behind.
//
// Scenarios are data, not code, so a run is reproducible and reviewable in a
// diff. Every step is recorded with its outcome; the run fails on the first
// step that does not do what it claims.
//
// usage: node drive.mjs <scenario.json> [--out <dir>] [--headed] [--base <url>]
//                       [--accept] [--require-baseline]
//
// Needs Playwright, installed OUTSIDE any project by scripts/drive-setup.sh
// (exactly lib/drive/package.json's playwrightVersion, in
// ${BENDIT_CACHE:-${XDG_CACHE_HOME:-~/.cache}/bendit}/drive/<version>/), and a
// browser already on the machine: Chrome by default, or whatever
// BENDIT_BROWSER_CHANNEL names. Neither present is exit 2, saying which.
//
// Exit: 0 VERIFIED; 1 NOT VERIFIED (a step failed, or --accept wrote a
// baseline); 2 could not run (usage, no base URL, refused --out, no
// Playwright, no browser).
//
// Snapshots are compared, not just written. A {"snapshot": "name"} step diffs
// the scrubbed tree against <scenario dir>/<scenario file>.baselines/name.aria.yml
// (committed, beside the scenario -- artifacts/ is gitignored, so evidence
// there is never a baseline). Rules, each copied from scripts/expect.sh:
//   - baseline exists, differs  -> the scenario FAILS, with a unified diff
//   - baseline exists, matches  -> ok
//   - no baseline               -> NOT a pass: said plainly, listed in the
//                                  verdict; exit stays 0 only so scenarios that
//                                  predate baselines keep working. --require-baseline
//                                  makes it a failure (use it in CI).
//   - --accept                  -> records the baseline and FAILS THE RUN, always.
//                                  A recorded baseline is a claim nobody has
//                                  checked; the only route to green is a second
//                                  run WITHOUT --accept that compares against it.
//                                  --accept is read from argv only, never the
//                                  environment, so a stray export cannot rewrite
//                                  baselines to match a regression.
import { readFileSync, mkdirSync, writeFileSync, rmSync, existsSync, readdirSync, realpathSync } from 'node:fs';
import { join, resolve, dirname, basename, relative, isAbsolute, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { tmpdir, homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const scenarioPath = argv[0];
if (!scenarioPath || scenarioPath === '--help') {
  console.error(`usage: drive.mjs <scenario.json> [--out <dir>] [--headed] [--base <url>]

scenario.json:
{
  "name": "entity-dashboard",
  "baseUrl": "http://localhost:8080",                // optional; see BASE URL below
  "storageState": "fixtures/auth-state/admin.json",   // optional
  "virtualAuthenticator": true,          // optional: enables passkey ceremonies
  "steps": [
    {"goto": "/admin/dashboard"},          // HTTP >= 400 fails the step...
    {"goto": "/admin/users", "expectStatus": 403},  // ...unless it is expected
    {"expectVisible": {"role": "heading", "name": "Entities"}},
    {"click": {"role": "link", "name": "Acme LLC"}},
    {"fill": {"label": "Legal name", "value": "Acme Holdings LLC"}},
    {"press": "Enter"},
    {"expectText": "Saved"},
    {"expectNotVisible": {"role": "button", "name": "Delete"}},
    {"saveState": "fixtures/auth-state/user.json"},
    {"screenshot": "after-save"}
  ]
}

BASE URL, first found wins: --base, then $PORT (http://localhost:$PORT), then
the scenario's baseUrl, then this checkout's port in bendit's registry. None
of them is exit 2: there is no default port.

Rules: "steps" must be non-empty; expectNotVisible means NO match is visible;
storageState and saveState are relative to the scenario's folder and must stay
inside it, and a saveState git would commit is refused (a login is a credential);
screenshot/snapshot names are reduced to one filename segment; --out must be
inside the working directory or the temp dir, and is replaced on every run.

Browser: Chrome, or BENDIT_BROWSER_CHANNEL (chrome, chrome-beta, msedge, ...).`);
  process.exit(argv[0] ? 0 : 2);
}
// LAST occurrence wins, as a CLI normally behaves. A harness appends its own
// `--out "$HERE/artifacts/..."` and then forwards "$@", so its path comes FIRST
// in argv; the caller overrides by appending a second --out. First-wins would
// ignore that silently, and silently ignored is the worst outcome, because the
// run looks configured when it is not.
const flag = (n, d) => { const i = argv.lastIndexOf(n); return i === -1 ? d : argv[i + 1]; };
const headed = argv.includes('--headed');
const accept = argv.includes('--accept');
const requireBaseline = argv.includes('--require-baseline');

const die = (m) => { console.error(`drive: ${m}`); process.exit(2); };
const KIT = fileURLToPath(new URL('../../', import.meta.url));

// --- Playwright, from the cache drive-setup.sh installs into -------------------
// Never from the project's node_modules: the project may pin another version,
// or none, and the driver must behave the same in every repo it verifies.
const pinned = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')).playwrightVersion;
const cacheRoot = process.env.BENDIT_CACHE
  || join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'bendit');
const pwDir = join(cacheRoot, 'drive', pinned);
const setupCmd = `bash ${join(KIT, 'scripts', 'drive-setup.sh')}`;
let chromium;
{
  const pkgFile = join(pwDir, 'node_modules', 'playwright', 'package.json');
  let found = null;
  try { found = JSON.parse(readFileSync(pkgFile, 'utf8')).version; } catch { /* not installed: said below */ }
  if (found !== pinned) {
    die(`Playwright ${pinned} is not installed for bendit (looked in ${pwDir}`
      + `${found ? `, found ${found}` : ''}). Install it with: ${setupCmd}`);
  }
  try {
    ({ chromium } = createRequire(pwDir + sep)('playwright'));
  } catch (err) {
    die(`Playwright ${pinned} in ${pwDir} would not load (${String(err.message).split('\n')[0]}). `
      + `Reinstall it: rm -rf ${pwDir} && ${setupCmd}`);
  }
}

let scenario;
try { scenario = JSON.parse(readFileSync(scenarioPath, 'utf8')); }
catch (err) { die(`cannot read scenario ${scenarioPath}: ${err.message}`); }

// BASE URL PRECEDENCE: --base, then PORT, then the scenario's own baseUrl.
//
// PORT outranks scenario.baseUrl because the scenario file is checked in and
// the port is assigned per checkout: a scenario that hard-codes
// http://localhost:3000 would otherwise navigate to whatever holds :3000 while
// the app under test answers on its real port.
//
// goto steps are already relative-friendly (see the goto handler below: an
// absolute URL passes through untouched, a relative one gets baseUrl).
const envPort = (process.env.PORT || '').trim();

// FOURTH SOURCE: bendit's port registry, asked directly.
//
// A person may run `verify-<repo> drive <scenario>` by hand, or this file
// directly, where nothing exported PORT. cwd is the repo (the harness cd's
// there first), so ports.py resolves the same port verify.sh would have
// assigned. An unregistered repo, a missing registry or no python3 falls
// through to the refusal below rather than inventing a port.
const registryPort = () => {
  try {
    const r = spawnSync('python3', [join(KIT, 'scripts', 'ports.py'), 'port', process.cwd()],
      { encoding: 'utf8', timeout: 10000 });
    const out = (r.stdout || '').trim();
    return r.status === 0 && /^[0-9]+$/.test(out) ? `http://localhost:${out}` : null;
  } catch {
    return null;
  }
};
// Each source is tried only if every earlier one is absent. Not
// `flag('--base', fallback)`: a default argument is evaluated BEFORE flag()
// looks at argv, so the die() in the fallback would fire even with --base.
const baseUrl = flag('--base', null)
  || (/^[0-9]+$/.test(envPort) ? `http://localhost:${envPort}` : null)
  || scenario.baseUrl
  || registryPort()
  || die('no base URL: pass --base, set PORT, give the scenario a baseUrl, or register '
       + 'this repo (python3 ' + join(KIT, 'scripts', 'ports.py') + ' add .). It is NOT '
       + 'defaulted to :3000 -- another app may hold that port, and driving its pages '
       + 'through this scenario produces confident nonsense.');
const runId = `${scenario.name || 'run'}-${process.env.RUN_STAMP || new Date().toISOString().replace(/[:.]/g, '-')}`;
const outDir = resolve(flag('--out', join('artifacts', runId)));

// --out is about to be rm -rf'd, and it is caller input: `--out ..` would
// delete the parent of the repo. Resolve symlinks (macOS /var -> /private/var)
// on the deepest part that exists, then demand: strictly inside cwd or a temp
// dir; never /, $HOME, the git toplevel, or cwd or any of its ancestors; and,
// if it already holds files, that a previous drive run made it (marker file).
const OUT_MARKER = '.bendit-drive-evidence';
const real = (p) => {
  let head = resolve(p), tail = [];
  while (!existsSync(head) && dirname(head) !== head) { tail.unshift(basename(head)); head = dirname(head); }
  return join(realpathSync(head), ...tail);
};
const inside = (child, parent) => { const r = relative(parent, child); return !!r && !r.startsWith('..') && !isAbsolute(r); };
{
  const out = real(outDir), cwd = real(process.cwd());
  const refuse = (why) => die(`REFUSING --out ${outDir}: ${why}. It is deleted before the run.`);
  const tmpRoots = [...new Set([tmpdir(), '/tmp'].filter(existsSync).map(real))];
  const top = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' });
  const forbidden = [real('/'), real(homedir()), ...(top.status === 0 ? [real(top.stdout.trim())] : [])];
  if (forbidden.includes(out)) refuse('it is /, $HOME or the repository root');
  if (out === cwd || inside(cwd, out)) refuse('it is the working directory or one of its ancestors');
  if (!inside(out, cwd) && !tmpRoots.some((t) => inside(out, t))) refuse('it is outside both the working directory and the temp dir');
  if (existsSync(out) && readdirSync(out).length && !existsSync(join(out, OUT_MARKER))) {
    refuse(`it already holds files and no ${OUT_MARKER} marker, so a drive run did not make it`);
  }
}

// --- saved logins: beside the scenario, and never where git would commit them ---
// storageState and saveState hold a session: cookies and tokens, a credential.
// Both resolve against the scenario file's folder, as baselines do, so the
// same scenario reads and writes the same file whatever the cwd. A path that
// leaves that folder is refused, and so is a saveState that git would commit
// (the scaffold git-ignores scenarios/fixtures/auth-state/). Checked before
// the browser starts, so a refused scenario touches nothing.
const scenarioDir = dirname(resolve(scenarioPath));
const statePath = (key, p) => {
  if (typeof p !== 'string' || !p) die(`REFUSING ${key} ${JSON.stringify(p)}: it must be a path`);
  const dest = resolve(scenarioDir, p);
  if (!inside(real(dest), real(scenarioDir))) {
    die(`REFUSING ${key} ${p}: it resolves to ${dest}, outside the scenario's folder ${scenarioDir}. `
      + 'A saved login is a credential: keep it under the scenario\'s folder (fixtures/auth-state/ is git-ignored there).');
  }
  return dest;
};
const storageStatePath = scenario.storageState ? statePath('storageState', scenario.storageState) : null;
const saveStatePaths = new Map();
for (const step of Array.isArray(scenario.steps) ? scenario.steps : []) {
  if (!step || typeof step !== 'object' || !('saveState' in step)) continue;
  const dest = statePath('saveState', step.saveState);
  // Fail CLOSED: allowed only when git says the path is ignored (0), or says the
  // folder is genuinely outside any repository (nothing can commit it). A missing
  // git, or git failing for any other reason, is "could not confirm", not "fine".
  const gitText = (r) => (r.error ? r.error.code === 'ENOENT' ? 'git not found' : r.error.message
    : String(r.stderr || '').trim().split('\n')[0] || `git exited ${r.status}`);
  const refuse = (why) => die(`REFUSING saveState ${step.saveState}: could not confirm ${dest} is git-ignored: ${why}. `
    + 'A saved login is a credential; fix git, or save under fixtures/auth-state/ once git works.');
  const ig = spawnSync('git', ['-C', scenarioDir, 'check-ignore', '-q', dest], { encoding: 'utf8' });
  if (ig.status === 1) {
    die(`REFUSING saveState ${step.saveState}: ${dest} is not git-ignored, so git would commit `
      + 'the saved login. Save it under fixtures/auth-state/ (the scaffold ignores that folder), '
      + 'or add the path to .gitignore.');
  }
  if (ig.status !== 0) {
    if (ig.error || ig.status === null) refuse(gitText(ig));
    const rp = spawnSync('git', ['-C', scenarioDir, 'rev-parse', '--is-inside-work-tree'], { encoding: 'utf8' });
    const notRepo = !rp.error && rp.status !== null && rp.status !== 0 && /not a git repository/i.test(String(rp.stderr || ''));
    if (!notRepo) refuse(gitText(ig.status === 128 && String(ig.stderr || '').trim() ? ig : rp));
  }
  saveStatePaths.set(step, dest);
}

// --- the browser, BEFORE the previous evidence is touched -------------------------
// A machine with no Chrome must not cost the last run's evidence, and must not
// read as a failed scenario: it is "could not run" (exit 2), saying which
// browser was looked for and how to choose another.
const channel = process.env.BENDIT_BROWSER_CHANNEL || 'chrome';
let browser;
try {
  browser = await chromium.launch({ channel, headless: !headed });
} catch (err) {
  die(`could not launch the browser: channel "${channel}" `
    + `(${process.env.BENDIT_BROWSER_CHANNEL ? 'from BENDIT_BROWSER_CHANNEL' : 'the default'}) `
    + `was not found or would not start -- ${String(err.message).split('\n')[0]}. `
    + 'Install Google Chrome (https://www.google.com/chrome/), or set BENDIT_BROWSER_CHANNEL '
    + 'to a browser this machine has (chrome, chrome-beta, msedge, msedge-beta). '
    + 'bendit never downloads a browser.');
}

// A run must never inherit artifacts from a previous one: a stale FAILED-step
// screenshot sitting inside a VERIFIED run is exactly the misleading evidence
// this harness exists to prevent.
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, OUT_MARKER), 'written by bendit drive.mjs; this directory is replaced on every run\n');

// A step name becomes a FILENAME, and a scenario is author-supplied input:
// `"snapshot": "../../x"` would write outside the evidence dir. One path segment only.
const safeName = (name) => {
  const s = String(name).replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '_');
  if (s !== String(name)) console.log(`  note  step name "${name}" -> "${s}" for the filename`);
  return s;
};

const baselineDir = join(dirname(resolve(scenarioPath)), `${basename(scenarioPath)}.baselines`);
const shown = p => { const r = relative(process.cwd(), p); return r && !r.startsWith('..') ? r : p; };
const uncompared = [], accepted = [];

// Compare one scrubbed snapshot to its committed baseline. Returns a detail
// string for an ok step; throws (after printing the diff) for a failing one.
function compareSnapshot(name, fresh, freshPath) {
  const safe = safeName(name);
  const base = join(baselineDir, `${safe}.aria.yml`);
  const had = existsSync(base);
  const old = had ? readFileSync(base, 'utf8') : null;
  if (accept) {
    if (had && old === fresh) return `matches baseline ${shown(base)} (unchanged)`;
    mkdirSync(baselineDir, { recursive: true });
    writeFileSync(base, fresh);
    accepted.push(base);
    throw new Error(`ACCEPTED ${shown(base)} -- ${had ? 'baseline REWRITTEN' : 'baseline recorded'}; ` +
      `read it (git diff), then re-run WITHOUT --accept. This run fails on purpose.`);
  }
  if (!had) {
    uncompared.push(base);
    if (requireBaseline) throw new Error(`no baseline at ${shown(base)} (--require-baseline)`);
    return `NOT COMPARED: no baseline at ${shown(base)} -- run with --accept to record one, review it, then re-run`;
  }
  if (old === fresh) return `matches baseline ${shown(base)}`;
  const tmp = join(tmpdir(), `bendit-drive-${process.pid}-${safe}.yml`);
  writeFileSync(tmp, fresh);
  const d = spawnSync('diff', ['-u', '--label', `baseline ${shown(base)}`, '--label', `this run ${shown(freshPath)}`, base, tmp], { encoding: 'utf8' });
  rmSync(tmp, { force: true });
  console.log(`     snapshot "${name}" differs from ${shown(base)}:`);
  console.log((d.stdout || `(diff unavailable: ${d.error?.message ?? d.stderr})`).trimEnd().split('\n').map(l => '       ' + l).join('\n'));
  console.log('     If the change is intended: re-run with --accept, read the diff in git, re-run without it.');
  throw new Error(`snapshot "${name}" differs from baseline ${shown(base)}`);
}

const log = [];
const record = (i, step, status, detail) => {
  const entry = { i, step: Object.keys(step)[0], status, detail };
  log.push(entry);
  const mark = status === 'ok' ? 'ok  ' : 'FAIL';
  console.log(`${mark} ${String(i).padStart(2)}  ${entry.step}${detail ? '  — ' + detail : ''}`);
};

// Roles and accessible names only. Never generated classes, hashes or indexes:
// those change when nothing about the behaviour changed, and a harness that
// breaks on a refactor stops being run.
/** Take the values that change for no reason out of an aria snapshot.
 *
 *  A snapshot is only worth keeping if you can DIFF it against the last one,
 *  and a diff that is noisy every run gets accepted blind -- worse than no
 *  snapshot, because it still looks like a check. Two things are scrubbed and
 *  a third is deliberately left alone:
 *
 *  - the ORIGIN, because each checkout takes its own port from the registry,
 *    and a snapshot that changes with the port says nothing about the app
 *  - UUIDs, because a fixture row's id is regenerated and means nothing
 *  - COUNTS ARE NOT SCRUBBED. "Total 13" becoming "Total 82" can be another
 *    user's rows leaking into this one's view, the most valuable thing a
 *    snapshot can catch. Quietening the diff by scrubbing numbers would remove
 *    the reason to keep it.
 *
 *  The consequence is real and is not hidden: a page whose numbers come from
 *  shared seed data WILL diff whenever that data moves. Snapshot such a page
 *  only once its scenario seeds and cleans its own rows; until then snapshot
 *  the structural pages and assert the numbers explicitly. */
function scrub(aria) {
  return String(aria)
    .replace(/https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?/g, '<origin>')
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '<uuid>');
}

const locate = (page, sel) => {
  if (typeof sel === 'string') return page.getByText(sel, { exact: false });
  if (sel.role) return page.getByRole(sel.role, { name: sel.name, exact: false });
  if (sel.label) return page.getByLabel(sel.label, { exact: false });
  if (sel.placeholder) return page.getByPlaceholder(sel.placeholder);
  if (sel.testId) return page.getByTestId(sel.testId);
  if (sel.text) return page.getByText(sel.text, { exact: false });
  throw new Error(`unaddressable selector: ${JSON.stringify(sel)}`);
};

let failed = false;
try {
  const ctx = await browser.newContext(
    storageStatePath ? { storageState: storageStatePath } : {}
  );
  const page = await ctx.newPage();

  // WebAuthn: attach a CDP virtual authenticator so a passkey step can be
  // driven. Without this, an app gated on a passkey is undrivable -- the
  // browser has no authenticator and the ceremony cannot start.
  // Opt-in per scenario with "virtualAuthenticator": true, because it changes
  // what the page can do and should never be on by accident.
  if (scenario.virtualAuthenticator) {
    const cdp = await ctx.newCDPSession(page);
    await cdp.send('WebAuthn.enable');
    const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
      options: {
        protocol: 'ctap2',
        transport: 'internal',
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true,
      },
    });
    console.log(`     virtual authenticator attached (${authenticatorId})`);
  }

  const consoleLines = [], requests = [];
  page.on('console', m => consoleLines.push(`[${m.type()}] ${m.text()}`));
  page.on('requestfailed', r => requests.push(`FAILED ${r.method()} ${r.url()} ${r.failure()?.errorText ?? ''}`));
  page.on('response', r => { if (r.status() >= 400) requests.push(`${r.status()} ${r.request().method()} ${r.url()}`); });

  // A scenario that checks nothing must not print VERIFIED.
  if (!Array.isArray(scenario.steps) || scenario.steps.length === 0) {
    throw new Error('scenario has no steps -- nothing would be checked, so it cannot be VERIFIED');
  }
  for (const [i, step] of scenario.steps.entries()) {
    const timeout = step.timeout ?? 10000;
    try {
      if (step.goto !== undefined) {
        const url = /^[a-z][a-z0-9+.-]*:\/\//i.test(step.goto) ? step.goto : baseUrl + step.goto;
        const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
        // A 500 page still renders, so a goto that only LOGS the status lets
        // the next step pass on an error page. >= 400 fails unless the step
        // says that status is the point: {"goto": "/admin", "expectStatus": 403}.
        const st = res ? res.status() : null;
        if (step.expectStatus !== undefined) {
          if (st !== step.expectStatus) throw new Error(`expected HTTP ${step.expectStatus}, got ${st ?? 'no response'} for ${url}`);
        } else if (st !== null && st >= 400) {
          throw new Error(`HTTP ${st} for ${url} (add "expectStatus": ${st} if that is what this step proves)`);
        }
        record(i, step, 'ok', `${st ?? 'no response'} ${url}`);
      } else if (step.click) {
        await locate(page, step.click).first().click({ timeout });
        record(i, step, 'ok');
      } else if (step.fill) {
        await locate(page, step.fill).first().fill(step.fill.value, { timeout });
        record(i, step, 'ok', JSON.stringify(step.fill.value));
      } else if (step.press) {
        await page.keyboard.press(step.press);
        record(i, step, 'ok', step.press);
      } else if (step.expectVisible) {
        await locate(page, step.expectVisible).first().waitFor({ state: 'visible', timeout });
        record(i, step, 'ok');
      } else if (step.expectNotVisible) {
        // NONE may be visible. `.first()` alone checked only the first match,
        // so a hidden "Delete" before a visible one passed. Filtering to the
        // visible matches first keeps hidden-in-DOM ([hidden], display:none)
        // counting as not visible, which is the normal way a UI hides things.
        await locate(page, step.expectNotVisible).filter({ visible: true }).first()
          .waitFor({ state: 'hidden', timeout });
        record(i, step, 'ok');
      } else if (step.expectText) {
        await page.getByText(step.expectText, { exact: false }).first()
          .waitFor({ state: 'visible', timeout });
        record(i, step, 'ok', JSON.stringify(step.expectText));
      } else if (step.screenshot) {
        const p = join(outDir, `${safeName(step.screenshot)}.png`);
        await page.screenshot({ path: p, fullPage: true });
        record(i, step, 'ok', p);
      } else if (step.snapshot) {
        const p = join(outDir, `${safeName(step.snapshot)}.aria.yml`);
        const fresh = scrub(await page.locator('body').ariaSnapshot());
        writeFileSync(p, fresh);
        record(i, step, 'ok', compareSnapshot(step.snapshot, fresh, p));
      } else if (step.evalJs) {
        // Read page state for diagnosis. Deliberately NOT for arranging the
        // symptom under test. Use it to find out why a scenario fails, not to
        // make one pass.
        const v = await page.evaluate(step.evalJs);
        record(i, step, 'ok', JSON.stringify(v).slice(0, 300));
      } else if (step.saveState) {
        // Capture the session AFTER a multi-stage login (password -> passkey ->
        // workspace). Minting a token is not enough for an app whose gate is
        // downstream of it; the only honest way to get that state is to
        // complete the real ceremony once and keep the result.
        const dest = saveStatePaths.get(step);
        mkdirSync(dirname(dest), { recursive: true });
        await ctx.storageState({ path: dest });
        record(i, step, 'ok', dest);
      } else if (step.waitMs) {
        await page.waitForTimeout(step.waitMs);
        record(i, step, 'ok', `${step.waitMs}ms`);
      } else {
        throw new Error(`unknown step: ${JSON.stringify(step)}`);
      }
    } catch (err) {
      record(i, step, 'fail', String(err.message).split('\n')[0]);
      failed = true;
      try { await page.screenshot({ path: join(outDir, `FAILED-step-${i}.png`), fullPage: true }); } catch {}
      break;
    }
  }

  writeFileSync(join(outDir, 'console.log'), consoleLines.join('\n'));
  writeFileSync(join(outDir, 'requests.log'), requests.join('\n'));
  writeFileSync(join(outDir, 'manifest.json'), JSON.stringify({
    scenario: scenario.name, baseUrl, runId, failed, uncompared, accepted,
    steps: log, consoleLines: consoleLines.length, badResponses: requests.length,
  }, null, 2));
  writeFileSync(join(outDir, 'verdict.md'),
    `# ${failed ? 'NOT VERIFIED' : 'VERIFIED'} — ${scenario.name}\n\n` +
    (uncompared.length ? `WARNING: ${uncompared.length} snapshot(s) had no baseline and were NOT compared:\n${uncompared.map(u => '  ' + u).join('\n')}\n\n` : '') +
    `base: ${baseUrl}\nsteps: ${log.filter(l => l.status === 'ok').length}/${scenario.steps.length} ok\n` +
    `console messages: ${consoleLines.length}\nHTTP >=400 or failed requests: ${requests.length}\n`);
} catch (err) {
  console.error(`drive: ${err.message}`);
  failed = true;
} finally {
  await browser?.close();
}
console.log(`\nevidence: ${outDir}`);
if (uncompared.length && !failed) console.log(`WARNING: ${uncompared.length} snapshot(s) NOT compared (no baseline) -- this run proves less than it looks`);
console.log(failed ? 'VERDICT: NOT VERIFIED' : 'VERDICT: VERIFIED');
process.exit(failed ? 1 : 0);
