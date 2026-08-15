#!/usr/bin/env bun
// router: switch which Claude account Claude Code uses.
//
// Each profile is a 1-year OAuth token minted through the same PKCE flow as
// `claude setup-token`. The token lives in the macOS Keychain (service
// "router", account = profile name).
//
// A switch swaps the "Claude Code-credentials" keychain item, so it applies
// to running sessions too: Claude Code re-reads the item on its next API
// call (~30s credential cache). "main" is the normal keychain login; its
// real credential is stashed (service "router-stash") while another profile
// is active and restored on switch-back.
//
// Race to know about: a long-running session that started as "main" can
// refresh its OAuth pair and rewrite the keychain item while another
// profile is active. `router heal` detects that (a synthetic item never has
// a refreshToken), re-stashes the fresh main credential, and re-asserts the
// active profile. The menu bar app calls it periodically.

import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createHash, randomBytes } from "node:crypto";

const HOME = homedir();
const DIR = join(HOME, ".router");
const CURRENT_FILE = join(DIR, "current");
const PROFILES_FILE = join(DIR, "profiles.json");
const PENDING_FILE = join(DIR, "pending.json");
const ACCOUNT_STASH_FILE = join(DIR, "stash-account.json");
const SERVICE = "router";
const STASH_SERVICE = "router-stash";
const CLAUDE_SERVICE = "Claude Code-credentials";
const CLAUDE_ACCOUNT = process.env.USER ?? "";
const CLAUDE_JSON = join(HOME, ".claude.json");
const MAIN = "main";
const NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const TOKEN_RE = /sk-ant-oat01-[A-Za-z0-9_.-]+/;

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const REDIRECT_URI = "https://platform.claude.com/oauth/code/callback";
const AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize";
const TOKEN_URL = "https://api.anthropic.com/v1/oauth/token";
const YEAR_MS = 365 * 24 * 3600 * 1000;

type Profile = {
  email?: string;
  plan?: string;
  tier?: string;
  addedAt: string;
  expiresAt?: number;
};
type Profiles = Record<string, Profile>;

function ensureDir() {
  mkdirSync(DIR, { recursive: true, mode: 0o700 });
}

function loadProfiles(): Profiles {
  try {
    return JSON.parse(readFileSync(PROFILES_FILE, "utf8")).profiles ?? {};
  } catch {
    return {};
  }
}

function saveProfiles(profiles: Profiles) {
  ensureDir();
  writeFileSync(PROFILES_FILE, JSON.stringify({ profiles }, null, 2) + "\n", { mode: 0o600 });
}

function currentName(): string {
  try {
    const name = readFileSync(CURRENT_FILE, "utf8").trim();
    return name || MAIN;
  } catch {
    return MAIN;
  }
}

function setCurrent(name: string) {
  ensureDir();
  writeFileSync(CURRENT_FILE, name + "\n", { mode: 0o600 });
}

// --- keychain ---------------------------------------------------------------

function keychainRead(service: string, account: string): string | null {
  const p = Bun.spawnSync(["security", "find-generic-password", "-s", service, "-a", account, "-w"]);
  if (p.exitCode !== 0) return null;
  const value = p.stdout.toString().replace(/\n$/, "");
  return value || null;
}

// Values with spaces/quotes (credential JSON) go through argv, not the
// `security -i` batch parser. The argv is visible in ps for the milliseconds
// the call runs; same exposure Claude Code's own credential tooling has on a
// single-user Mac.
function keychainWrite(service: string, account: string, value: string) {
  const p = Bun.spawnSync([
    "security", "add-generic-password", "-U", "-s", service, "-a", account, "-w", value,
  ]);
  if (p.exitCode !== 0) throw new Error(`keychain write failed: ${p.stderr.toString().trim()}`);
}

function keychainDelete(service: string, account: string) {
  Bun.spawnSync(["security", "delete-generic-password", "-s", service, "-a", account]);
}

// --- claude credential item ---------------------------------------------------

type ClaudeItem = Record<string, any>;

function readClaudeItem(): ClaudeItem | null {
  const raw = keychainRead(CLAUDE_SERVICE, CLAUDE_ACCOUNT);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function writeClaudeItem(item: ClaudeItem) {
  keychainWrite(CLAUDE_SERVICE, CLAUDE_ACCOUNT, JSON.stringify(item));
}

// A real login has a refresh token. A router-made item never does.
function isMainFamily(item: ClaudeItem | null): boolean {
  const refresh = item?.claudeAiOauth?.refreshToken;
  return typeof refresh === "string" && refresh.length > 0;
}

function syntheticItem(base: ClaudeItem | null, name: string, token: string): ClaudeItem {
  const profile = loadProfiles()[name];
  const item: ClaudeItem = { ...(base ?? {}) };
  item.claudeAiOauth = {
    accessToken: token,
    expiresAt: profile?.expiresAt ?? Date.now() + YEAR_MS,
    scopes: ["user:inference"],
    subscriptionType: profile?.plan === "pro" ? "pro" : "max",
  };
  return item;
}

function stashMain(item: ClaudeItem) {
  keychainWrite(STASH_SERVICE, MAIN, JSON.stringify(item));
  try {
    const cfg = JSON.parse(readFileSync(CLAUDE_JSON, "utf8"));
    if (cfg.oauthAccount) {
      writeFileSync(ACCOUNT_STASH_FILE, JSON.stringify(cfg.oauthAccount) + "\n", { mode: 0o600 });
    }
  } catch {}
}

function readStash(): ClaudeItem | null {
  const raw = keychainRead(STASH_SERVICE, MAIN);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function dropStash() {
  keychainDelete(STASH_SERVICE, MAIN);
  rmSync(ACCOUNT_STASH_FILE, { force: true });
}

// Display metadata in ~/.claude.json. Auth ignores it; /status shows it.
function patchAccountEmail(email: string | undefined) {
  if (!email) return;
  try {
    const cfg = JSON.parse(readFileSync(CLAUDE_JSON, "utf8"));
    if (!cfg.oauthAccount) return;
    cfg.oauthAccount.emailAddress = email;
    writeFileSync(CLAUDE_JSON, JSON.stringify(cfg, null, 2));
  } catch {}
}

function restoreAccountStash() {
  try {
    const stashed = JSON.parse(readFileSync(ACCOUNT_STASH_FILE, "utf8"));
    const cfg = JSON.parse(readFileSync(CLAUDE_JSON, "utf8"));
    cfg.oauthAccount = stashed;
    writeFileSync(CLAUDE_JSON, JSON.stringify(cfg, null, 2));
  } catch {}
}

function mainEmail(): string | null {
  try {
    const stashed = JSON.parse(readFileSync(ACCOUNT_STASH_FILE, "utf8"));
    if (stashed.emailAddress) return stashed.emailAddress;
  } catch {}
  try {
    const cfg = JSON.parse(readFileSync(CLAUDE_JSON, "utf8"));
    return cfg.oauthAccount?.emailAddress ?? null;
  } catch {
    return null;
  }
}

// --- oauth ------------------------------------------------------------------

function b64url(buf: Buffer): string {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function authStart(): string {
  const verifier = b64url(randomBytes(32));
  const state = b64url(randomBytes(32));
  const challenge = b64url(createHash("sha256").update(verifier).digest());
  ensureDir();
  writeFileSync(PENDING_FILE, JSON.stringify({ verifier, state, ts: Date.now() }) + "\n", {
    mode: 0o600,
  });
  const q = new URLSearchParams({
    code: "true",
    client_id: CLIENT_ID,
    response_type: "code",
    redirect_uri: REDIRECT_URI,
    scope: "user:inference",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  });
  return `${AUTHORIZE_URL}?${q}`;
}

type Redeemed = { token: string; email?: string; expiresAt?: number };

async function authRedeem(paste: string): Promise<Redeemed> {
  let pending: { verifier: string; state: string };
  try {
    pending = JSON.parse(readFileSync(PENDING_FILE, "utf8"));
  } catch {
    throw new Error("no sign-in in progress — start one first");
  }
  const [code, pastedState] = paste.trim().split("#");
  if (!code) throw new Error("empty code");
  const r = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code,
      state: pastedState ?? pending.state,
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      code_verifier: pending.verifier,
    }),
  });
  const body: any = await r.json().catch(() => ({}));
  if (!r.ok) {
    throw new Error(`sign-in failed: ${body.error_description ?? body.error ?? `HTTP ${r.status}`}`);
  }
  rmSync(PENDING_FILE, { force: true });
  const token = typeof body.access_token === "string" ? body.access_token : null;
  if (!token || !TOKEN_RE.test(token)) throw new Error("no token in the response");
  const email =
    body.account?.email_address ?? body.account?.email ?? body.email ?? undefined;
  const expiresAt =
    typeof body.expires_in === "number" ? Date.now() + body.expires_in * 1000 : undefined;
  return { token, email, expiresAt };
}

// --- profile bookkeeping ------------------------------------------------------

function deriveName(email: string | undefined, profiles: Profiles): string {
  let base = (email ?? "")
    .split("@")[0]!
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^[-_]+|[-_]+$/g, "")
    .slice(0, 24);
  if (!base) base = "account";
  if (base === MAIN) base = "account";
  let name = base;
  for (let i = 2; profiles[name]; i++) name = `${base}${i}`;
  return name;
}

function saveNewProfile(explicit: string | undefined, redeemed: Redeemed): { name: string; profile: Profile } {
  const profiles = loadProfiles();
  let name = explicit;
  if (!name) {
    const existing = redeemed.email
      ? Object.entries(profiles).find(([, p]) => p.email === redeemed.email)?.[0]
      : undefined;
    name = existing ?? deriveName(redeemed.email, profiles);
  }
  const profile: Profile = {
    email: redeemed.email,
    addedAt: new Date().toISOString(),
    expiresAt: redeemed.expiresAt ?? Date.now() + YEAR_MS,
  };
  keychainWrite(SERVICE, name, redeemed.token);
  profiles[name] = profile;
  saveProfiles(profiles);
  return { name, profile };
}

// --- commands -----------------------------------------------------------------

function die(msg: string): never {
  console.error(`router: ${msg}`);
  process.exit(1);
}

function validName(name: string | undefined): string {
  if (!name) die("profile name is required");
  if (name === MAIN) die(`"${MAIN}" is reserved for the keychain login`);
  if (!NAME_RE.test(name)) die("name must match [a-z0-9][a-z0-9_-]* (max 32 chars)");
  return name;
}

function switchTo(name: string) {
  const item = readClaudeItem();
  if (name === MAIN) {
    if (isMainFamily(item)) {
      // Already holding real login credentials (never left, a session's
      // refresh reverted the swap, or the user ran /login). Keep them.
      dropStash();
    } else {
      const stashed = readStash();
      if (!stashed) {
        die("the main login credential is missing — run `claude /login` once, then retry");
      }
      // Connectors may have re-authed while away; keep the newest mcpOAuth.
      if (item?.mcpOAuth) stashed.mcpOAuth = item.mcpOAuth;
      writeClaudeItem(stashed);
      restoreAccountStash();
      dropStash();
    }
    setCurrent(MAIN);
    return;
  }

  const profiles = loadProfiles();
  const profile = profiles[name];
  if (!profile) die(`no profile "${name}" — see: router list`);
  const token = keychainRead(SERVICE, name);
  if (!token) die(`profile "${name}" has no keychain token — re-add it`);
  if (isMainFamily(item)) stashMain(item!);
  writeClaudeItem(syntheticItem(item, name, token));
  patchAccountEmail(profile.email);
  setCurrent(name);
}

function cmdUse(args: string[]) {
  const name = args[0];
  if (!name) die("usage: router use <name|main>");
  switchTo(name);
  console.log(`Switched to "${name}". Sessions pick it up on their next request (about 30s).`);
}

// A running "main" session can refresh its OAuth pair and rewrite the
// keychain item while a profile is active. Re-stash the fresh credential and
// re-assert the profile.
function cmdHeal(args: string[]) {
  const cur = currentName();
  if (cur === MAIN) return;
  const item = readClaudeItem();
  if (!isMainFamily(item)) return;
  const token = keychainRead(SERVICE, cur);
  if (!token) return;
  stashMain(item!);
  writeClaudeItem(syntheticItem(item, cur, token));
  patchAccountEmail(loadProfiles()[cur]?.email);
  if (!args.includes("--quiet")) console.log(`healed: re-asserted "${cur}" after a main refresh`);
}

async function cmdAdd(args: string[]) {
  const paste = args.includes("--paste");
  let name = args.find((a) => !a.startsWith("--"));
  if (name) {
    name = validName(name);
    if (loadProfiles()[name]) die(`profile "${name}" exists — remove it first`);
  }

  let redeemed: Redeemed;
  if (paste) {
    const raw = prompt("Paste a sk-ant-oat01-… token:")?.trim() ?? "";
    const token = raw.match(TOKEN_RE)?.[0];
    if (!token) die("that does not look like a sk-ant-oat01-… token");
    redeemed = { token };
  } else {
    const url = authStart();
    console.log("Opening the Claude sign-in in your browser.");
    console.log("Tip: use a private window for an account that is not your browser default.\n");
    console.log(url + "\n");
    Bun.spawnSync(["open", url]);
    const code = prompt("Paste the code from the sign-in page:")?.trim() ?? "";
    if (!code) die("no code pasted");
    redeemed = await authRedeem(code);
  }

  const saved = saveNewProfile(name, redeemed);
  console.log(`\nAdded "${saved.name}"${saved.profile.email ? ` (${saved.profile.email})` : ""}.`);
  if (!saved.profile.email) {
    console.log(`No email came back with the token. Rename if you like: router rename ${saved.name} <name>`);
  }
  console.log(`Switch with: router use ${saved.name}`);
}

// Machine surface for the menu bar app.
async function cmdAuth(args: string[]) {
  const sub = args[0];
  if (sub === "start") {
    const url = authStart();
    console.log(JSON.stringify({ url }));
    return;
  }
  if (sub === "redeem") {
    const paste = args[1];
    if (!paste) die("usage: router auth redeem <code>");
    try {
      const redeemed = await authRedeem(paste);
      const saved = saveNewProfile(undefined, redeemed);
      console.log(JSON.stringify({ name: saved.name, email: saved.profile.email ?? null }));
    } catch (e: any) {
      console.log(JSON.stringify({ error: e.message ?? String(e) }));
      process.exit(1);
    }
    return;
  }
  die("usage: router auth start|redeem");
}

async function listData() {
  const current = currentName();
  const profiles = loadProfiles();
  const rows = [
    {
      name: MAIN,
      email: mainEmail() ?? undefined,
      plan: undefined as string | undefined,
      source: "keychain",
      current: current === MAIN,
    },
    ...Object.entries(profiles).map(([name, p]) => ({
      name,
      email: p.email,
      plan: p.plan,
      source: "token",
      current: current === name,
    })),
  ];
  return { current, profiles: rows };
}

async function cmdList(args: string[]) {
  const data = await listData();
  if (args.includes("--json")) {
    console.log(JSON.stringify(data));
    return;
  }
  for (const p of data.profiles) {
    const mark = p.current ? "*" : " ";
    const plan = p.plan ? ` (${p.plan})` : "";
    console.log(`${mark} ${p.name.padEnd(14)} ${p.email ?? "?"}${plan} [${p.source}]`);
  }
}

async function cmdCurrent(args: string[]) {
  const data = await listData();
  const cur = data.profiles.find((p) => p.current)!;
  if (args.includes("--json")) console.log(JSON.stringify(cur));
  else console.log(`${cur.name}${cur.email ? ` (${cur.email})` : ""}`);
}

function cmdToken(args: string[]) {
  const name = args[0] ?? currentName();
  if (name === MAIN) die("the main profile uses the keychain login, not a stored token");
  const token = keychainRead(SERVICE, name);
  if (!token) die(`no keychain token for "${name}"`);
  console.log(token);
}

function cmdRename(args: string[]) {
  const from = validName(args[0]);
  const to = validName(args[1]);
  const profiles = loadProfiles();
  if (!profiles[from]) die(`no profile "${from}"`);
  if (profiles[to]) die(`profile "${to}" exists`);
  const token = keychainRead(SERVICE, from);
  if (!token) die(`no keychain token for "${from}"`);
  keychainWrite(SERVICE, to, token);
  keychainDelete(SERVICE, from);
  profiles[to] = profiles[from]!;
  delete profiles[from];
  saveProfiles(profiles);
  if (currentName() === from) setCurrent(to);
  console.log(`Renamed "${from}" to "${to}".`);
}

function cmdRemove(args: string[]) {
  const name = validName(args[0]);
  const profiles = loadProfiles();
  if (!profiles[name]) die(`no profile "${name}"`);
  if (currentName() === name) {
    switchTo(MAIN);
    console.log(`"${name}" was active — switched back to "${MAIN}".`);
  }
  keychainDelete(SERVICE, name);
  delete profiles[name];
  saveProfiles(profiles);
  console.log(`Removed "${name}".`);
}

async function cmdDoctor() {
  let ok = true;
  const report = (good: boolean, msg: string) => {
    console.log(`${good ? "ok " : "BAD"}  ${msg}`);
    if (!good) ok = false;
  };

  const cur = currentName();
  const profiles = loadProfiles();
  report(cur === MAIN || !!profiles[cur], `current profile "${cur}" exists`);

  const item = readClaudeItem();
  report(!!item, "Claude Code keychain item present");
  if (cur === MAIN) {
    report(isMainFamily(item), "keychain holds the real login (has a refresh token)");
  } else {
    const token = keychainRead(SERVICE, cur);
    report(!!token, `keychain token for "${cur}"`);
    report(
      item?.claudeAiOauth?.accessToken === token,
      "keychain item matches the active profile (run `router heal` if not)",
    );
    report(!!readStash(), "main login stashed for switch-back");
  }
  for (const name of Object.keys(profiles)) {
    report(!!keychainRead(SERVICE, name), `token stored for "${name}"`);
  }

  try {
    const sl = readFileSync(join(HOME, ".claude/statusline.sh"), "utf8");
    report(sl.includes("router"), "statusline shows the account segment");
  } catch {
    report(false, "statusline script not found");
  }

  const app = Bun.spawnSync(["pgrep", "-x", "Router"]);
  report(app.exitCode === 0, "menu bar app is running");
  process.exit(ok ? 0 : 1);
}

function help() {
  console.log(`router — switch Claude Code accounts

usage:
  router add [name] [--paste]   sign in and store a 1-year token
  router use <name|main>        switch every session to this account
  router list [--json]          show all profiles
  router current [--json]       show the active profile
  router rename <old> <new>     rename a profile
  router token [name]           print a profile's stored token
  router remove <name>          delete a profile and its token
  router heal [--quiet]         re-assert the active profile after a refresh race
  router doctor                 check the installation
  router auth start|redeem      machine surface for the menu bar app

"main" is the normal keychain login. A switch swaps the keychain credential,
so running sessions follow on their next request (about 30s).`);
}

const [cmd, ...rest] = process.argv.slice(2);
switch (cmd) {
  case "add": await cmdAdd(rest); break;
  case "use": cmdUse(rest); break;
  case "heal": cmdHeal(rest); break;
  case "auth": await cmdAuth(rest); break;
  case "list": await cmdList(rest); break;
  case "current": await cmdCurrent(rest); break;
  case "token": cmdToken(rest); break;
  case "rename": cmdRename(rest); break;
  case "remove": cmdRemove(rest); break;
  case "doctor": await cmdDoctor(); break;
  default: help(); process.exit(cmd ? 1 : 0);
}
