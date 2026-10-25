#!/usr/bin/env bash
# Installs the subagent-statusline patch into /opt/claude-code/bin/claude (run with sudo)
# and a pacman hook that re-applies it after every claude-code upgrade.
# Uninstall: sudo ./install.sh --uninstall   (restores the unpatched binary via pacman)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

lib=/usr/local/lib/claude-subagent-statusline
hook=/etc/pacman.d/hooks/claude-code-subagent-statusline.hook
bin=/opt/claude-code/bin/claude

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$lib" "$hook"
  pacman -S --noconfirm claude-code   # reinstall = unpatched binary
  exit 0
fi

# Root-owned copy, so the hook never executes user-writable code as root
install -Dm644 "$(dirname "$(readlink -f "$0")")/patch.py" "$lib/patch.py"
install -Dm755 /dev/stdin "$lib/apply.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bin=/opt/claude-code/bin/claude
tmp=$(mktemp "$bin.patch.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if ! python3 /usr/local/lib/claude-subagent-statusline/patch.py "$bin" "$tmp"; then
  echo "claude-subagent-statusline: patch not applied (binary left unchanged)" >&2
  exit 0
fi
chmod 755 "$tmp"
DISABLE_UPDATES=1 "$tmp" --version >/dev/null
mv -f "$tmp" "$bin"
trap - EXIT
echo "claude-subagent-statusline: patched $bin"
EOF

install -Dm644 /dev/stdin "$hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = claude-code

[Action]
Description = Patching Claude Code statusline for subagent views...
When = PostTransaction
Exec = /usr/local/lib/claude-subagent-statusline/apply.sh
EOF

"$lib/apply.sh"
