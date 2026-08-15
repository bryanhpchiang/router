#!/usr/bin/env bun
// router: pick which Claude account new Claude Code sessions use.
//
// Each profile is a 1-year OAuth token from `claude setup-token`. The token
// lives in the macOS Keychain (service "router", account = profile name).
// The claude shim in ~/.router/bin reads ~/.router/current and exports
// CLAUDE_CODE_OAUTH_TOKEN before it execs the real binary. The pseudo
// profile "main" means: no override, use the normal keychain login.
//
// Switches apply to NEW claude sessions only. A running session keeps the
// account it started with. `claude -c` after a switch continues the same
// conversation on the new account.

import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();
const DIR = join(HOME, ".router");
const CURRENT_FILE = join(DIR, "current");
const PROFILES_FILE = join(DIR, "profiles.json");
const SERVICE = "router";
const MAIN = "main";
const NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const TOKEN_RE = /sk-ant-oat01-[A-Za-z0-9_.-]+/;

type Profile = { email?: string; plan?: string; tier?: string; addedAt: string };
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

// --- keychain -------------------------------------------------------------

function keychainGet(name: string): string | null {
  const p = Bun.spawnSync(["security", "find-generic-password", "-s", SERVICE, "-a", name, "-w"]);
  if (p.exitCode !== 0) return null;
  const token = p.stdout.toString().trim();
  return token || null;
}

function keychainSet(name: string, token: string) {
  // Batch mode keeps the token off the process argument list.
  if (!/^[A-Za-z0-9_.-]+$/.test(token)) throw new Error("token has unexpected characters");
  const cmd = `add-generic-password -U -s ${SERVICE} -a ${name} -w ${token}\n`;
  const p = Bun.spawnSync(["security", "-i"], { stdin: Buffer.from(cmd) });
  if (p.exitCode !== 0) throw new Error(`keychain write failed: ${p.stderr.toString().trim()}`);
}

function keychainDelete(name: string) {
  Bun.spawnSync(["security", "delete-generic-password", "-s", SERVICE, "-a", name]);
}

// --- claude ---------------------------------------------------------------

function realClaude(): string {
  const candidates = [
    join(HOME, ".local/bin/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  const found = Bun.which("claude");
  if (found && !found.startsWith(join(DIR, "bin"))) return found;
  throw new Error("cannot find the claude binary");
}

function mainEmail(): string | null {
  try {
    const cfg = JSON.parse(readFileSync(join(HOME, ".claude.json"), "utf8"));
    return cfg.oauthAccount?.emailAddress ?? null;
  } catch {
    return null;
  }
}

type OauthProfile = { email?: string; plan?: string; tier?: string };

async function fetchOauthProfile(token: string): Promise<OauthProfile> {
  const r = await fetch("https://api.anthropic.com/api/oauth/profile", {
    headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
  });
  if (!r.ok) throw new Error(`token check failed: HTTP ${r.status}`);
  const j: any = await r.json();
  const plan = j.account?.has_claude_max ? "max" : j.account?.has_claude_pro ? "pro" : "free";
  return { email: j.account?.email, plan, tier: j.organization?.rate_limit_tier };
}

// --- commands -------------------------------------------------------------

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

async function captureSetupToken(): Promise<string | null> {
  // stdout is piped so we can grab the token; the passthrough keeps the
  // instructions visible. stdin stays on the terminal for the paste-back
  // step of the OAuth flow.
  const proc = Bun.spawn([realClaude(), "setup-token"], {
    stdin: "inherit",
    stdout: "pipe",
    stderr: "inherit",
  });
  let buf = "";
  const decoder = new TextDecoder();
  for await (const chunk of proc.stdout) {
    const s = decoder.decode(chunk);
    buf += s;
    process.stdout.write(s);
  }
  await proc.exited;
  return buf.match(TOKEN_RE)?.[0] ?? null;
}

function deriveName(email: string | undefined, profiles: Profiles): string {
  let base = (email ?? "")
    .split("@")[0]!
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^[-_]+|[-_]+$/g, "")
    .slice(0, 24);
  if (!base || base === MAIN) base = "account";
  let name = base;
  for (let i = 2; profiles[name]; i++) name = `${base}${i}`;
  return name;
}

async function cmdAdd(args: string[]) {
  const paste = args.includes("--paste");
  let name = args.find((a) => !a.startsWith("--"));
  if (name) {
    name = validName(name);
    if (loadProfiles()[name]) die(`profile "${name}" exists — remove it first`);
  }

  let token: string | null = null;
  if (paste) {
    const raw = prompt("Paste the token from `claude setup-token`:")?.trim() ?? "";
    token = raw.match(TOKEN_RE)?.[0] ?? null;
    if (!token) die("that does not look like a sk-ant-oat01-… token");
  } else {
    console.log("Opening the Claude sign-in. Log in as the account you want to add.");
    console.log("Tip: use a private browser window for an account that is not your browser default.\n");
    token = await captureSetupToken();
    if (!token) {
      die("no token captured. Run `claude setup-token` yourself, then run\n  router add --paste");
    }
  }

  const info = await fetchOauthProfile(token);
  const profiles = loadProfiles();
  if (!name) {
    // No label step: name the profile after the account email. Re-adding
    // the same account refreshes its token under the existing name.
    const existing = info.email
      ? Object.entries(profiles).find(([, p]) => p.email === info.email)?.[0]
      : undefined;
    name = existing ?? deriveName(info.email, profiles);
  }
  keychainSet(name, token);
  profiles[name] = { ...info, addedAt: new Date().toISOString() };
  saveProfiles(profiles);
  console.log(`\nAdded "${name}" (${info.email ?? "unknown"}, ${info.plan}).`);
  console.log(`Switch with: router use ${name}`);
}

function cmdUse(args: string[]) {
  const name = args[0];
  if (!name) die("usage: router use <name|main>");
  if (name !== MAIN) {
    if (!loadProfiles()[name]) die(`no profile "${name}" — see: router list`);
    if (!keychainGet(name)) die(`profile "${name}" has no keychain token — re-add it`);
  }
  setCurrent(name);
  console.log(`New claude sessions run as "${name}".`);
  console.log("Running sessions keep their account. `claude -c` reopens a conversation on the new one.");
}

async function listData() {
  const current = currentName();
  const profiles = loadProfiles();
  const rows = [
    { name: MAIN, email: mainEmail() ?? undefined, plan: undefined as string | undefined, source: "keychain", current: current === MAIN },
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
    console.log(`${mark} ${p.name.padEnd(12)} ${p.email ?? "?"}${plan} [${p.source}]`);
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
  const token = keychainGet(name);
  if (!token) die(`no keychain token for "${name}"`);
  console.log(token);
}

function cmdRemove(args: string[]) {
  const name = validName(args[0]);
  const profiles = loadProfiles();
  if (!profiles[name]) die(`no profile "${name}"`);
  keychainDelete(name);
  delete profiles[name];
  saveProfiles(profiles);
  if (currentName() === name) {
    setCurrent(MAIN);
    console.log(`Removed "${name}". Current profile is back to "${MAIN}".`);
  } else {
    console.log(`Removed "${name}".`);
  }
}

async function cmdDoctor() {
  let ok = true;
  const report = (good: boolean, msg: string) => {
    console.log(`${good ? "ok " : "BAD"}  ${msg}`);
    if (!good) ok = false;
  };

  const shim = join(DIR, "bin", "claude");
  report(existsSync(shim), `shim at ${shim}`);
  const which = Bun.which("claude");
  report(which === shim, `PATH resolves claude to the shim (got: ${which ?? "nothing"})`);
  try {
    report(true, `real binary: ${realClaude()}`);
  } catch {
    report(false, "real claude binary not found");
  }

  const cur = currentName();
  const profiles = loadProfiles();
  report(cur === MAIN || !!profiles[cur], `current profile "${cur}" exists`);
  for (const name of Object.keys(profiles)) {
    report(!!keychainGet(name), `keychain token for "${name}"`);
  }

  try {
    const sl = readFileSync(join(HOME, ".claude/statusline.sh"), "utf8");
    report(sl.includes("ROUTER_PROFILE"), "statusline shows the account segment");
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
  router add [name] [--paste]   add an account (straight to the Claude sign-in)
  router use <name|main>        route new claude sessions to this account
  router list [--json]          show all profiles
  router current [--json]       show the active profile
  router token [name]           print a profile's stored token
  router remove <name>          delete a profile and its token
  router doctor                 check the installation

"main" is the normal keychain login. Switches apply to new sessions only.`);
}

const [cmd, ...rest] = process.argv.slice(2);
switch (cmd) {
  case "add": await cmdAdd(rest); break;
  case "use": cmdUse(rest); break;
  case "list": await cmdList(rest); break;
  case "current": await cmdCurrent(rest); break;
  case "token": cmdToken(rest); break;
  case "remove": cmdRemove(rest); break;
  case "doctor": await cmdDoctor(); break;
  default: help(); process.exit(cmd ? 1 : 0);
}
