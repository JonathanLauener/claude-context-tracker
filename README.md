# claude-context-tracker

A live context window tracker for the [Claude Code](https://claude.com/claude-code) statusline.
It shows how full the model's context is, how long the current task has been running, and
a rough estimate of how long it has left:

```
Opus 5.5  ██████░░░░░░░░░░░░░░ 30%  60.4k / 200.0k                    ⏱ 2m01s · ~22m49s übrig
```

- **Left:** model name, a 20-cell bar (green below 50%, yellow from 50%, red from 80%), and
  used / total tokens.
- **Right-aligned:** elapsed time of the current turn and an ETA learned from your past turns,
  or `✓ fertig in 3m12s` when the turn has finished.
- **Optional:** with the subagent patch, opening a subagent's view (footer agent list → Enter)
  switches the bar to *that* agent's context: `↳ Explore · Haiku 4.5  ████░░…`.

## Install

Requirements: `bash`, `jq`, `awk`, `ps` (plus `python3` and `sudo` for the optional patch).

```bash
git clone https://github.com/JonathanLauener/claude-context-tracker.git
cd claude-context-tracker
./setup.sh                    # statusline only, works on any Claude Code install
./setup.sh --subagent-patch   # + binary patch for subagent views (Arch `claude-code` package only)
```

Restart Claude Code afterwards. Setup:

1. backs up your existing `statusline.sh` / `statusline-eta.sh` and `statusLine` setting to
   `~/.claude/backups/context-tracker/` (first install only, so re-running it is safe),
2. copies both scripts to `~/.claude/`,
3. sets `statusLine` in `~/.claude/settings.json` without touching any other key,
4. runs a smoke test with a fake payload.

`CLAUDE_CONFIG_DIR` is respected if your config lives elsewhere.

**Uninstall:** `./setup.sh --uninstall` restores the previous statusline and setting. The binary
patch is removed separately: `sudo subagent-patch/install.sh --uninstall`.

## How it's integrated

### 1. The statusline hook

Claude Code can run a command to draw its statusline. Setup adds this to `settings.json`:

```json
"statusLine": { "type": "command", "command": "/home/you/.claude/statusline.sh", "padding": 0 }
```

On every update Claude Code pipes a JSON payload into the command's stdin and shows the first
line it prints (ANSI colors work). The fields used here:

| Field | Used for |
|---|---|
| `model.display_name`, `model.id` | label; `[1m]` in the id means a 1M-token window |
| `context_window.context_window_size` | total size of the window |
| `context_window.current_usage` | tokens currently in context |
| `transcript_path` | fallback for usage, and the source for the timer/ETA |
| `viewed_agent` | only present with the subagent patch (see below) |

### 2. Counting context (`statusline.sh`)

Used context = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the
latest request, which is what the model actually saw. Output tokens are left out: they only
count once they are part of the next request's input.

If the payload doesn't include `context_window` (older Claude Code versions), the script reads
the transcript (JSONL) backwards and takes the `usage` of the last main-thread assistant message,
skipping subagent (`isSidechain`) entries. If the window size is missing too, it assumes 200k,
or 1M when the model id ends in `[1m]`.

### 3. Timer and ETA (`statusline-eta.sh`)

A jq program splits transcripts into turns. A turn starts with a real user prompt (string
content that isn't a slash command or meta message) and ends with the last assistant message
before the next prompt. The durations of finished turns from the 8 most recent transcripts in
the same project are the history.

For the running turn the estimate is conditional: among past turns that ran **at least as long
as this one has so far**, take the median total duration; remaining = median − elapsed. A
quick question that has already run 10 minutes gets compared to other long tasks, not to all
the 20-second ones. With fewer than 3 past turns it only shows elapsed time. If the turn has
outlasted everything in the history, it says so.

Claude Code runs the statusline command without a TTY, so the script can't simply ask for the
terminal width. To right-align the timer it walks up the parent processes until one has a TTY,
reads that terminal's width with `stty -F /dev/<tty> size`, and pads the line. If none is found
it falls back to a `│` separator.

> The ETA strings are German (`übrig` = left, `fertig in` = done in,
> `noch zu wenig Daten für ETA` = not enough data yet, `länger als alle bisherigen Tasks` =
> longer than all previous tasks). They're plain `printf`s at the bottom of
> `statusline-eta.sh` if you want to change them.

### 4. Subagent view (`subagent-patch/`, optional)

Normally, when you open a subagent's view, the statusline keeps reporting the **main**
conversation's context. Claude Code doesn't expose which agent you're viewing to the statusline
command, so this part patches the binary.

Claude Code is distributed as a [Bun](https://bun.sh) standalone executable. Each bundled
module ships as source **and** precompiled JavaScriptCore bytecode, and Bun runs the bytecode,
so editing the source alone does nothing. `patch.py`:

1. finds the `.bun` ELF section and its module table (52-byte entries),
2. locates the two modules by unique anchor strings: the statusline store/JSON builder and the
   statusline React component,
3. applies small source edits:
   - the component reads `viewingAgentTaskId` and that task's transcript from app state,
     publishes it as `globalThis.__ccView`, and asks the store to refresh when it changes;
   - the store computes `context_window` from the viewed agent's messages instead of the main
     ones, adds a `viewed_agent` object (`agent_type`, `description`, `status`, `model`, …), and
     uses the agent's own model for the label and the window size,
4. keeps every module at its exact byte length by shortening the license header comment, so
   no offsets in the binary move,
5. sets each patched module's bytecode length to 0, so Bun falls back to running the source.

Cost: about 0.3 s extra startup, since two modules get parsed from source.

`statusline.sh` then shows `↳ <agent_type> · <model>` whenever `viewed_agent` is present.
Without the patch the field never appears and nothing changes.

`subagent-patch/install.sh` (run through `setup.sh --subagent-patch`):

- copies `patch.py` to root-owned `/usr/local/lib/claude-subagent-statusline/`, so the
  root-run hook never executes a user-writable file,
- installs a pacman hook (`/etc/pacman.d/hooks/claude-code-subagent-statusline.hook`) that
  re-applies the patch after every `claude-code` upgrade,
- patches into a temp file, checks it with `claude --version`, and only then replaces
  `/opt/claude-code/bin/claude`.

**Version caveat:** the anchors are minified names from Claude Code **2.1.283**. When a new
version renames them, `patch.py` stops with `anchor found 0x`, the hook leaves the binary
unpatched, and Claude Code works normally, only without subagent tracking. To update, search
the new binary for strings like `viewingAgentTaskId`, `context_window_size` and `getMessages:`
to find the new names, then adjust the anchors in `patch.py`.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | install / uninstall |
| `statusline.sh` | statusline entry point: model, context bar, layout |
| `statusline-eta.sh` | elapsed time + ETA from transcript history |
| `subagent-patch/patch.py` | patches the Bun binary (`patch.py <in> <out>`) |
| `subagent-patch/install.sh` | root install of the patch + pacman hook |

## Disclaimer

The subagent patch modifies the Claude Code binary. It isn't affiliated with or supported by
Anthropic. Use it at your own risk, and uninstall it before reporting Claude Code bugs.
