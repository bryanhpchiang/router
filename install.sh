#!/bin/bash
# Install router: state dir, claude shim, PATH entry. Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/.router"
BIN="$DIR/bin"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

# The shim must exec the real binary, never itself.
REAL=""
for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -x "$c" ] && REAL="$c" && break
done
[ -n "$REAL" ] || { echo "install: cannot find the real claude binary" >&2; exit 1; }

mkdir -p "$BIN"
chmod 700 "$DIR"

# claude shim: inject the selected account's token into new sessions.
cat > "$BIN/claude" <<SHIM
#!/bin/sh
# router shim (see ~/Documents/router). Pins new Claude Code sessions to the
# profile in ~/.router/current. Explicit auth env vars win over the shim.
REAL="$REAL"
if [ -z "\$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "\$ANTHROPIC_API_KEY" ] && [ -z "\$ANTHROPIC_AUTH_TOKEN" ]; then
  cur=\$(cat "\$HOME/.router/current" 2>/dev/null)
  if [ -n "\$cur" ] && [ "\$cur" != "main" ]; then
    tok=\$(security find-generic-password -s router -a "\$cur" -w 2>/dev/null)
    if [ -n "\$tok" ]; then
      export CLAUDE_CODE_OAUTH_TOKEN="\$tok"
      export ROUTER_PROFILE="\$cur"
    fi
  fi
fi
exec "\$REAL" "\$@"
SHIM
chmod 755 "$BIN/claude"

# router launcher: absolute bun path so the menu bar app can call it too.
cat > "$BIN/router" <<LAUNCHER
#!/bin/sh
exec "$BUN" "$REPO/cli/router.ts" "\$@"
LAUNCHER
chmod 755 "$BIN/router"

# Terminal one-shot for the menu bar "Add Account" item.
cat > "$DIR/add.command" <<'CMD'
#!/bin/zsh
"$HOME/.router/bin/router" add
CMD
chmod 755 "$DIR/add.command"

# PATH: append at the end of .zshrc so this prepend wins over earlier ones.
MARK="# router: per-session Claude account (see ~/Documents/router)"
if ! grep -qF "$MARK" "$HOME/.zshrc" 2>/dev/null; then
  printf '\n%s\nexport PATH="$HOME/.router/bin:$PATH"\n' "$MARK" >> "$HOME/.zshrc"
  echo "added ~/.router/bin to PATH in ~/.zshrc (open a new terminal)"
fi

echo "installed. try: router list"
