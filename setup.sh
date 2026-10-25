#!/usr/bin/env bash
# Installs the context window tracker as the Claude Code statusline.
#
#   ./setup.sh                    install statusline.sh + statusline-eta.sh into ~/.claude
#                                 and point settings.json's "statusLine" at it
#   ./setup.sh --subagent-patch   also patch the Claude Code binary so the bar follows the
#                                 subagent you're viewing (Arch pkg claude-code only, needs sudo)
#   ./setup.sh --uninstall        restore the previous statusline (the binary patch is removed
#                                 separately: sudo subagent-patch/install.sh --uninstall)
#
# Honors CLAUDE_CONFIG_DIR if you keep your Claude config somewhere other than ~/.claude.
set -euo pipefail

repo=$(dirname "$(readlink -f "$0")")
dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
settings=$dir/settings.json
backup=$dir/backups/context-tracker
cmd="$dir/statusline.sh"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

uninstall() {
  if [[ -d "$backup" ]]; then
    for f in statusline.sh statusline-eta.sh; do
      if [[ -f "$backup/$f" ]]; then cp -f "$backup/$f" "$dir/$f"; say "restored $f"
      else rm -f "$dir/$f"; fi
    done
    # Put back only the old "statusLine" key, so other settings changed since install survive
    if [[ -f "$settings" && -f "$backup/statusLine.json" ]]; then
      jq --slurpfile old "$backup/statusLine.json" \
        'if $old[0] == null then del(.statusLine) else .statusLine = $old[0] end' \
        "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
      say "restored statusLine in settings.json"
    fi
    rm -rf "$backup"
  else
    rm -f "$dir/statusline.sh" "$dir/statusline-eta.sh"
    [[ -f "$settings" ]] && jq 'del(.statusLine)' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
    say "removed statusline (no backup found)"
  fi
  if [[ -f /etc/pacman.d/hooks/claude-code-subagent-statusline.hook ]]; then
    say "the subagent patch is still installed; remove it with: sudo $repo/subagent-patch/install.sh --uninstall"
  fi
  say "done — restart Claude Code"
}

patch=0
case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  --subagent-patch) patch=1 ;;
  "") ;;
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

for dep in jq awk ps; do command -v "$dep" >/dev/null || die "missing dependency: $dep"; done
mkdir -p "$dir" "$backup"

# First install only: back up what was there before (statusLine.json marks a backup as taken)
if [[ ! -f "$backup/statusLine.json" ]]; then
  for f in statusline.sh statusline-eta.sh; do
    if [[ -f "$dir/$f" ]]; then cp "$dir/$f" "$backup/$f"; say "backed up $f -> $backup/"; fi
  done
  if [[ -s "$settings" ]]; then jq '.statusLine' "$settings" >"$backup/statusLine.json" || die "$settings is not valid JSON"
  else echo null >"$backup/statusLine.json"; fi
fi

install -m755 "$repo/statusline.sh" "$dir/statusline.sh"
install -m755 "$repo/statusline-eta.sh" "$dir/statusline-eta.sh"
say "installed statusline.sh + statusline-eta.sh into $dir"

[[ -s "$settings" ]] || echo '{}' >"$settings"
jq --arg cmd "$cmd" '.statusLine = {type: "command", command: $cmd, padding: 0}' "$settings" >"$settings.tmp" \
  || { rm -f "$settings.tmp"; die "$settings is not valid JSON"; }
mv "$settings.tmp" "$settings"
say "set statusLine in $settings"

# Smoke test with a fake statusline payload
out=$(echo '{"model":{"display_name":"Test","id":"test"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}' \
  | "$dir/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g')
[[ "$out" == *"25%"* ]] || die "smoke test failed, got: $out"
say "smoke test ok: $out"

if (( patch )); then
  [[ -x /opt/claude-code/bin/claude ]] && command -v pacman >/dev/null \
    || die "--subagent-patch only supports the Arch package (pacman, /opt/claude-code/bin/claude)"
  command -v python3 >/dev/null || die "missing dependency: python3"
  say "installing subagent patch (sudo)"
  sudo "$repo/subagent-patch/install.sh"
fi

say "done — restart Claude Code to see it"
