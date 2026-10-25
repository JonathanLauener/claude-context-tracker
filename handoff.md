# Handoff: claude-context-tracker

## What this is
Public-facing packaging of the user's Claude Code statusline (context bar + ETA) and the optional
subagent-view binary patch. Repo: github.com/JonathanLauener/claude-context-tracker (public since 2026-10-25).
README.md explains the integration in detail.

## Sources of truth
- Live install on this machine: `~/.claude/statusline.sh`, `~/.claude/statusline-eta.sh`,
  patch in `/usr/local/lib/claude-subagent-statusline/` + pacman hook (installed from
  `~/scripts/claude-subagent-statusline/`, which has the reverse-engineering notes in its handoff.md).
- Repo copy differs from the live `statusline.sh` only in: comment path, and it calls
  `statusline-eta.sh` next to itself instead of the hardcoded `~/.claude/` path.
  `./setup.sh` has NOT been run on the live config (live is already equivalent).

## setup.sh behavior (tested 2026-10-25 with CLAUDE_CONFIG_DIR in scratch)
- First install backs up old scripts + `.statusLine` value to `$dir/backups/context-tracker/`
  (`statusLine.json` is the "backup taken" marker); re-runs don't overwrite the backup.
- `--uninstall` restores only the statusLine key (other settings survive), removes or restores
  the scripts, and only prints the command to remove the binary patch (no sudo).
- `--subagent-patch` requires pacman + `/opt/claude-code/bin/claude`, runs `sudo subagent-patch/install.sh`.

## Open / ideas
- ETA strings are German; README documents them. Could add an English/locale switch.
- Patch anchors are tied to Claude Code 2.1.283.
