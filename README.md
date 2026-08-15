# router

Switch Claude Code between Claude accounts. One CLI, a `claude` shim, a
statusline segment, and a menu bar app.

Each added account is a 1-year OAuth token from `claude setup-token`. The
token lives in the macOS Keychain (service `router`). No re-login is needed
until the token expires.

## How it works

- `~/.router/current` holds the selected profile name.
- `~/.router/bin/claude` is a shim that comes first in `PATH`. At launch it
  reads `current`, pulls that profile's token from the Keychain, and exports
  `CLAUDE_CODE_OAUTH_TOKEN` and `ROUTER_PROFILE`. Then it execs the real
  binary.
- The profile `main` is the normal keychain login. The shim then exports
  nothing.
- A switch applies to new sessions only. A running session keeps its
  account. Run `claude -c` after a switch to continue the same conversation
  on the new account.

## Install

```bash
./install.sh                        # shim + CLI + PATH entry in ~/.zshrc
menubar/Scripts/install_app.sh      # Router.app + start at login
```

The statusline segment is a patch to `~/.claude/statusline.sh` (already
applied): the pink first segment shows `ROUTER_PROFILE`, or the login email
for keychain sessions. The usage curl in that script prefers
`CLAUDE_CODE_OAUTH_TOKEN`, and the usage cache is per profile.

## Use

```bash
router add work        # opens the Claude login; add the other account there
router use work        # new claude sessions run as "work"
router use main        # back to the keychain login
router list
router doctor
```

If `router add` cannot capture the token, run `claude setup-token` yourself
and run `router add work --paste`.

The menu bar app shows the active profile. Click it to switch, or to open
"Add Account…" in Terminal.

## Caveats

- `claude setup-token` opens your default browser. The browser's claude.ai
  session picks the account. Use a private window to add a different
  account.
- Only shells that read `~/.zshrc` get the shim. An app that calls the
  binary by absolute path bypasses the router and runs as `main`.
- The statusline usage segments for token profiles come from the OAuth
  usage endpoint with the profile's token. This is verified for normal
  access tokens, not yet for `setup-token` tokens.
- Tokens expire after about 1 year. Then: `router remove work` and
  `router add work`.
