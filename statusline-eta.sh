#!/usr/bin/env bash
# Prints elapsed time of the current task + rough ETA based on past task durations.
# Usage: statusline-eta.sh <transcript_path>
transcript="$1"
[[ -f "$transcript" ]] || exit 0
dir=$(dirname "$transcript")

# jq: turn durations (seconds) from a transcript. A "prompt" is a real user message
# (string content, not a command/meta); a turn ends at the last assistant entry before the next prompt.
read -r -d '' TURNS <<'JQ'
def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def is_prompt: .type=="user" and (.isMeta|not) and (.isSidechain|not)
  and ((.message.content|type)=="string") and (.message.content|startswith("<")|not);
[ .[] | select(.timestamp) |
  if is_prompt then {k:"p", t:(.timestamp|ts)}
  elif .type=="assistant" and (.isSidechain|not) then {k:"a", t:(.timestamp|ts), end:(.message.stop_reason=="end_turn")}
  else empty end ]
| reduce .[] as $e ({turns:[], cur:null};
    if $e.k=="p" then {turns:(.turns + (if .cur and .cur.last then [{d:(.cur.last-.cur.start), done:.cur.done}] else [] end)), cur:{start:$e.t, last:null, done:false}}
    elif .cur then .cur.last=$e.t | .cur.done=$e.end
    else . end)
JQ

# History: completed turns from the most recent transcripts in this project
hist=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n 8 | while read -r f; do
  tail -n 4000 "$f" | jq -s -r "$TURNS | (.turns + (if .cur and .cur.done then [{d:(.cur.last-.cur.start),done:true}] else [] end))[] | select(.done and .d>2) | .d" 2>/dev/null
done | sort -n)

# Current turn in this transcript
cur=$(tail -n 4000 "$transcript" | jq -s -r "$TURNS | .cur | if . then \"\(.start) \(.done)\" else empty end" 2>/dev/null)
[[ -z "$cur" ]] && exit 0
read -r start done <<<"$cur"
now=$(date +%s)
elapsed=$(( now - start ))

dur() { local s=$1; (( s < 60 )) && printf '%ds' "$s" || { (( s < 3600 )) && printf '%dm%02ds' $((s/60)) $((s%60)) || printf '%dh%02dm' $((s/3600)) $((s%3600/60)); }; }

if [[ "$done" == "true" ]]; then
  last=$(tail -n 4000 "$transcript" | jq -s -r "$TURNS | .cur | (.last-.start)" 2>/dev/null)
  printf '\033[2m✓ fertig in %s\033[0m' "$(dur "${last:-0}")"
  exit 0
fi

n=$(grep -c . <<<"$hist")
if (( n < 3 )); then
  printf '⏱ %s \033[2m(noch zu wenig Daten für ETA)\033[0m' "$(dur "$elapsed")"
  exit 0
fi
# Conditional estimate: among past tasks that took at least as long as we've run so far,
# take their median total duration -> remaining = median - elapsed
longer=$(awk -v e="$elapsed" '$1>=e' <<<"$hist")
m=$(grep -c . <<<"$longer")
if (( m == 0 )); then
  printf '⏱ %s \033[33m· länger als alle bisherigen Tasks\033[0m' "$(dur "$elapsed")"
else
  med=$(awk '{a[NR]=$1} END{print int(a[int((NR+1)/2)])}' <<<"$longer")
  rem=$(( med - elapsed )); (( rem < 5 )) && rem=5
  printf '⏱ %s \033[2m·\033[0m ~%s übrig' "$(dur "$elapsed")" "$(dur "$rem")"
fi
