# Agent setup guide

Deterministic steps to install router for a user. Run them in order. Each
step has a verification command; do not continue past a failed check.

## 1. Preconditions

```bash
sw_vers -productVersion        # must be 15.0 or newer
command -v bun                 # must print a path (install: https://bun.sh)
swift --version                # must print a Swift 6+ toolchain
security find-generic-password -s "Claude Code-credentials" -a "$USER" -w >/dev/null && echo logged-in
```

The last check must print `logged-in`. If it does not, have the user run
`claude` and log in first.

## 2. Install the CLI

```bash
git clone https://github.com/bryanhpchiang/router
cd router
./install.sh
export PATH="$HOME/.router/bin:$PATH"   # current shell; new shells get it from ~/.zshrc
router list                              # must show the user's login email, starred
```

## 3. Install the menu bar app

```bash
menubar/Scripts/install_app.sh
pgrep -x Router && echo running          # must print "running"
```

## 4. Add another account (needs the user)

`router add` opens a browser sign-in that only the user can complete. Tell
them: sign in as the account to add (private window if it is not the
browser default), copy the code, paste it at the prompt. Or have them click
"Add Account…" in the menu bar item, which does the same in a window.

Verify:

```bash
router list      # the new account's email appears
router doctor    # every line must start with "ok"
```

## 5. Behavior to relay to the user

- Switching applies to running sessions within about 30 seconds; nothing
  restarts, and conversations survive.
- `router use main` returns to the normal login.
- Statusline integration is optional; see README "Statusline".

## Files an agent may touch

- `~/.router/` — state (current selection, profile metadata, bin/)
- `~/.zshrc` — one PATH line, marked `# router:`
- `~/Applications/Router.app`, `~/Library/LaunchAgents/dev.bryan.router.plist`
- Keychain services `router`, `router-stash`, and the swapped
  `Claude Code-credentials` item

Never print token values. Read them only with `security` when a check
requires presence, and discard the output.
