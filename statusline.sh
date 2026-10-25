#!/usr/bin/env bash
# Statusline: model + context window usage (live)
input=$(cat)
model=$(jq -r '.model.display_name // "?"' <<<"$input")
model_id=$(jq -r '.model.id // ""' <<<"$input")
transcript=$(jq -r '.transcript_path // ""' <<<"$input")
# Set by the patched binary while a subagent's view is open (see subagent-patch/)
agent=$(jq -r '.viewed_agent.agent_type // empty' <<<"$input")
label=$model; [[ -n "$agent" ]] && label="↳ $agent · $model"

# Context window size: prefer what Claude Code reports, else guess from model id
size=$(jq -r '.context_window.context_window_size // empty' <<<"$input")
if [[ -z "$size" ]]; then
  [[ "$model_id" == *"[1m]"* ]] && size=1000000 || size=200000
fi

# Used tokens: prefer reported value, else last assistant usage from transcript
used=$(jq -r '(.context_window.current_usage // empty) |
  if type=="object" then ((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0)) else . end' <<<"$input" 2>/dev/null)
if [[ -z "$used" && -f "$transcript" ]]; then
  used=$(tac "$transcript" | jq -r 'select(.message.usage and (.isSidechain|not)) |
    .message.usage | (.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0)' 2>/dev/null | head -n1)
fi
used=${used:-0}

pct=$(( used * 100 / size ))
filled=$(( pct / 5 )); (( filled > 20 )) && filled=20
bar=''; for ((i=0;i<20;i++)); do (( i<filled )) && bar+='█' || bar+='░'; done

if   (( pct >= 80 )); then c='\033[31m'
elif (( pct >= 50 )); then c='\033[33m'
else c='\033[32m'; fi

fmt() { awk -v n="$1" 'BEGIN{ if(n>=1000000) printf "%.2fM", n/1e6; else if(n>=1000) printf "%.1fk", n/1e3; else printf "%d", n }'; }
printf "\033[36m%s\033[0m  ${c}%s %d%%\033[0m  %s / %s" "$label" "$bar" "$pct" "$(fmt "$used")" "$(fmt "$size")"

# Right side: elapsed time + ETA of the current task
right=$("$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/statusline-eta.sh" "$transcript")
[[ -z "$right" ]] && exit 0
# Terminal width: find the tty of an ancestor process (statusline runs without one)
cols=""; pid=$$
for _ in 1 2 3 4 5; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '); [[ -z "$pid" || "$pid" == 1 ]] && break
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  if [[ -n "$tty" && "$tty" != "?" ]]; then cols=$(stty -F "/dev/$tty" size 2>/dev/null | awk '{print $2}'); break; fi
done
strip() { sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
left_plain=$(strip "$(printf "%s  %s %d%%  %s / %s" "$label" "$bar" "$pct" "$(fmt "$used")" "$(fmt "$size")")")
right_plain=$(strip "$right")
pad=$(( ${cols:-0} - ${#left_plain} - ${#right_plain} - 4 ))
if (( pad > 2 )); then printf '%*s%s' "$pad" '' "$right"; else printf '   │ %s' "$right"; fi
