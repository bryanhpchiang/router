# router

Switch Claude Code between Claude accounts from the macOS menu bar or the
terminal.

Paste this into your agent (Claude Code) to get set up:

```text
Clone https://github.com/bryanhpchiang/router and follow its AGENTS.md to
install the router CLI and menu bar app. Verify each step. Stop and ask me
when a sign-in needs my browser.
```

- One click switches every session, running ones included.
- Accounts are identified by email. Tokens live in the macOS Keychain.
- Adding an account is one browser sign-in. Switching never asks you to
  log in again.
- The menu shows usage limits (5-hour and 7-day) per account.

## Manual install

Requirements:

- macOS 15 or newer, with the Xcode command line tools (`swift`)
- [Bun](https://bun.sh)
- Claude Code, logged in with a Claude subscription account

```bash
git clone https://github.com/bryanhpchiang/router
cd router
./install.sh                      # CLI + PATH entry in ~/.zshrc
menubar/Scripts/install_app.sh    # menu bar app, starts at login
```

## Use

Click the menu bar item to switch accounts or to add one. The same from the
terminal:

```bash
router add              # browser sign-in; paste the code; done
router use <name>       # switch every session to this account
router use main         # back to the normal keychain login
router list             # all accounts, active one starred
router usage            # usage limits per account
router remove <name>    # delete an account's token
router doctor           # check the installation
```

`router add` opens the Claude sign-in page. Sign in as the account you want
to add. Use a private browser window for an account that is not your
browser default. The profile takes its name from the account email.

## How it works

- `router add` runs the same OAuth (PKCE) flow as Claude Code's `/login`,
  with the full `/login` scope set (Remote Control needs it), and stores
  the token in the Keychain (service `router`).
- A switch swaps the `Claude Code-credentials` keychain item. Running
  Claude Code sessions re-read it on their next request; they cache the
  credential in memory for up to ~30 seconds, so a switch reaches them
  within that window. Conversations survive switches.
- `main` is your normal login. Its credential is stashed while another
  account is active, and restored on switch-back.
- A running `main` session can refresh its OAuth pair and overwrite the
  swap. The menu bar app runs `router heal` every 10 seconds, which
  re-stashes the fresh credential and re-asserts your selection.

State lives in `~/.router/` (no tokens on disk; tokens stay in the
Keychain).

## Statusline (optional)

To show the active account in the Claude Code statusline, resolve it like
this in your statusline script:

```bash
acct=$(cat "$HOME/.router/current" 2>/dev/null)
if [ -z "$acct" ] || [ "$acct" = "main" ]; then
  acct=$(jq -r '.oauthAccount.emailAddress // ""' "$HOME/.claude.json")
else
  acct=$(jq -r --arg n "$acct" '.profiles[$n].email // $n' "$HOME/.router/profiles.json")
fi
```

Optional, feeds `router usage` for switched accounts: persist the
`rate_limits` numbers your statusline receives on stdin:

```bash
[ -n "$five_pct" ] && printf '{"ts":%s,"five":%s,"week":%s}\n' \
  "$(date +%s)" "$five_pct" "${week_pct:-null}" \
  > "$HOME/.claude/cache/rate-limits-${acct_name:-main}.json"
```

## Uninstall

```bash
router use main
launchctl bootout "gui/$(id -u)/dev.bryan.router" 2>/dev/null
rm -rf ~/Applications/Router.app ~/Library/LaunchAgents/dev.bryan.router.plist ~/.router
# then delete the "router" and "router-stash" Keychain items and the
# PATH line in ~/.zshrc
```

## Caveats

- The sign-in page uses your browser's claude.ai session; the account you
  are logged into there is the account you add.
- If a switched account stops authenticating, run `router use main` and
  re-add it (tokens can expire; `router heal` renews them when the sign-in
  returned a refresh token).
- macOS only. Built for personal use; the credential layout it relies on
  is Claude Code internal and can change.
