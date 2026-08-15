#!/bin/bash
# Install router: state dir, CLI launcher, PATH entry. Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/.router"
BIN="$DIR/bin"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
[ -x "$BUN" ] || { echo "install: bun is required (https://bun.sh)" >&2; exit 1; }

mkdir -p "$BIN"
chmod 700 "$DIR"

# Launcher with an absolute bun path so the menu bar app can call it too.
cat > "$BIN/router" <<LAUNCHER
#!/bin/sh
exec "$BUN" "$REPO/cli/router.ts" "\$@"
LAUNCHER
chmod 755 "$BIN/router"

# Legacy artifacts from earlier designs.
rm -f "$BIN/claude" "$DIR/add.command"

MARK="# router: switch Claude Code accounts (see https://github.com/bryanhpchiang/router)"
if ! grep -q "^# router:" "$HOME/.zshrc" 2>/dev/null; then
  printf '\n%s\nexport PATH="$HOME/.router/bin:$PATH"\n' "$MARK" >> "$HOME/.zshrc"
  echo "added ~/.router/bin to PATH in ~/.zshrc (open a new terminal)"
fi

echo "installed. try: router list"
