#!/bin/bash
# mac-reaper 2: disk and memory watchdog for macOS, with a SwiftBar menu.
#
#   bash mac-reaper.sh --install          schedule the background check and add the SwiftBar plugin
#   bash mac-reaper.sh --install-plugin   add (or refresh) only the SwiftBar plugin
#   bash mac-reaper.sh --uninstall        remove the schedule and the plugin
#   bash mac-reaper.sh --status           disk, swap, what was cleared, what could be
#   bash mac-reaper.sh --report           build the full report and open it
#   bash mac-reaper.sh --dry-run          show what a clean-up would do, delete nothing
#   bash mac-reaper.sh --force            run a clean-up now, whatever the free space is
#   bash mac-reaper.sh --snooze 60        silence warnings for 60 minutes (0 = resume)
#
# How it decides:
#   Every item it could clear is either "safe" or "needs your OK".
#   Needs your OK = the app that owns it is open right now, or clearing it costs
#   you something (re-downloads, slower next build, files from your Trash).
#   When free disk drops below WARN_FREE_GB it clears the safe items by itself,
#   then shows a dialog listing the rest and waits for your answer.
#   It never quits apps and never touches documents, logs or crash reports.
#
# Settings: ~/.mac-reaper/config      Log: ~/.mac-reaper/reaper.log

set -u

VERSION="2.2"
REAPER_DIR="${REAPER_DIR:-$HOME/.mac-reaper}"
SELF="$REAPER_DIR/mac-reaper.sh"
LOG="$REAPER_DIR/reaper.log"
CAND="$REAPER_DIR/candidates.tsv"   # id, class (auto|confirm), KB (-1 unknown), label, reason
CACHES="$REAPER_DIR/caches.tsv"     # KB, owning app if open (or -), folder name
HIST="$REAPER_DIR/history.tsv"      # when, how (auto|approved|manual), KB freed, id, label
MEMFILE="$REAPER_DIR/memory.tsv"    # MB, app; biggest first, refreshed by each background check
LARGE="$REAPER_DIR/large.tsv"       # KB, label, what you can do; big things it leaves alone
SNOOZE="$REAPER_DIR/.snooze"        # epoch and label of when warnings resume
REPORT="$REAPER_DIR/report.html"
LABEL="local.mac-reaper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PLUGIN_NAME="mac-reaper.1m.sh"
TAB=$'\t'
# Menu bar icon: a scythe, 36x36 PNG at 144 dpi, drawn as a template so it follows light and dark bars.
ICON="iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAACXBIWXMAABYlAAAWJQFJUiTwAAACjklEQVR42s2XTYhOURjHf/fOB0bKRzSNJh8bQr0rUWyshCgWYmUlVjYyLKxGs7BRysLX3oaysJMiCQvZUGwkX8WUQZhp5r73tfk/9XS6Mffc+8516jRz733Pc/7n9zznPM9JqLclwXOnqoGyLVXvAHmBAPturf0vkbGCepwI3waAeXo/CUx3m5Ct1oSsBnYD24B1wCCwQCR+AR+Bl8BviRvV/1HuLKJibQdwW5N2SvRTGt9bVYwZWAvcDCaZUW+r5+ptINO3KT0fKFhcaZfa4EPAhETYZLmLJd+9YPvdk8DtlcScC4hk7m+Ra/JAUAfYX8VdXswlGZxWLxLwE/gqgpMFdF5ISFo1Zi7IcDjJU+C8YqIFDAFLgWXAMLAZeOvOnSNV6Nig0wH+D8AYsGkWNrbKpTnwBpgv6kns1t7niHwGzgBLApf26vepm8wWc8+NPxFLxwwPAj9k7Irc4emlf1lMAmxxu+0TsKgqnccytDMQksxy/C1H52wsHTM2IkErSgjxdDe62JkAlpelYxO2lYsWKi/lEpmVOCZypQajcR0Y13MWk2CHCpJomdhbo+MhV44b1vvosye2AjAiF13sXK2as2JrI78zv4tOBmyoi07sITrq6FxzdOZUkO2excAX0ZkBHgB7aaAZnZOuCvAJ95HOsjlxndEZAN65fHcMuOwqyft1BHcZOkddAn7ovq/XKd2qWpSVIdQHvHJ09mji/qZi56Cj8zy4g6VVC7KYy+EzR+dwXbeJ2CS8y9F5LTdFlRh10EFnjdE53jSd7Y7Oe1UIjdAxQXfc4TfSNJ2Wu9qMq85ujE4C3HBXm7Gm6Njq+3UZtKv0ym7kqZ4SuysDvgGrdEm8q/c5/0nrStz8AQdp2mtmJG9+AAAAAElFTkSuQmCC"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

[ -f "$REAPER_DIR/config" ] && . "$REAPER_DIR/config"

: "${WARN_FREE_GB:=10}"        # act when free disk drops below this (whole GB)
: "${CRIT_FREE_GB:=5}"         # urgent warning below this (whole GB)
: "${WARN_USED_PCT:=0}"        # also act when the disk is this % full; 0 = off
: "${SWAP_WARN_MB:=4096}"      # notify when swap in use passes this
: "${SWAP_CRIT_MB:=10240}"     # urgent notify (and optional colima stop) past this
: "${SWAP_RISE_MB:=1024}"      # also warn when swap grows this much between two checks
: "${AUTO_STOP_COLIMA:=0}"     # 1 = run "colima stop" when swap passes SWAP_CRIT_MB
: "${TRASH_MAX_AGE_DAYS:=30}"  # offer Trash items older than this; 0 = never touch Trash
: "${KEEP_CACHES:=}"           # names inside ~/Library/Caches to keep, colon-separated
: "${ASK_MIN_MB:=200}"         # only ask for your OK when at least this much is at stake
: "${DIALOG_TIMEOUT_SEC:=120}" # an unanswered dialog closes after this and counts as "not now"
: "${SCAN_EVERY_MIN:=30}"      # how often "could delete" sizes are refreshed when disk is fine
: "${NOTIFY_EVERY_MIN:=60}"    # minimum gap between repeats of the same warning or question
: "${INTERVAL_SEC:=600}"       # how often the schedule runs (applied on --install)

DRY_RUN=0
FORCE=0
ASSUME_YES=0
LOCK_HELD=0
MIN_KB=10240                   # items under 10 MB are not worth listing
FREED_KB=0
RUN_TABLE=""; RUN_IDS=""; RUN_WORDS=""

# ---------------------------------------------------------------- small helpers

log() {
  local line; line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  if [ -t 1 ] || [ "$DRY_RUN" = 1 ]; then echo "$line"; fi
  mkdir -p "$REAPER_DIR" 2>/dev/null && echo "$line" >> "$LOG"
}

gb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }

human() {
  awk -v k="$1" 'BEGIN{
    if (k < 0) printf "size unknown"
    else if (k < 1024) printf "%s", (k == 0 ? "0 MB" : "under 1 MB")
    else if (k < 1048576) printf "%d MB", k/1024
    else printf "%.1f GB", k/1048576 }'
}

clean() { printf '%s' "$1" | tr -d '\t|"\\\n\r'; }

html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

disk_read() {
  local t="/System/Volumes/Data"; [ -d "$t" ] || t="$HOME"
  set -- $(df -Pk "$t" 2>/dev/null | awk 'NR==2{print $2, $4}')
  DISK_TOTAL_KB=${1:-0}; DISK_FREE_KB=${2:-0}; DISK_PCT=0
  if [ "$DISK_TOTAL_KB" -gt 0 ]; then
    DISK_PCT=$(( (DISK_TOTAL_KB - DISK_FREE_KB) * 100 / DISK_TOTAL_KB ))
  fi
}

free_kb() { disk_read; echo "$DISK_FREE_KB"; }

is_low() {
  [ "$DISK_FREE_KB" -lt $((WARN_FREE_GB * 1048576)) ] && return 0
  [ "$WARN_USED_PCT" -gt 0 ] && [ "$DISK_PCT" -ge "$WARN_USED_PCT" ] && return 0
  return 1
}

is_crit() { [ "$DISK_FREE_KB" -lt $((CRIT_FREE_GB * 1048576)) ]; }

swap_used_mb() {
  sysctl -n vm.swapusage 2>/dev/null | awk '{
    for (i = 1; i < NF; i++) if ($i == "used") {
      v = $(i+2); u = substr(v, length(v)); n = substr(v, 1, length(v)-1) + 0
      if (u == "G") n *= 1024; if (u == "K") n /= 1024
      printf "%d", n; exit
    }}'
}

# Kernel memory pressure: 1 normal, 2 warning, 4 critical. Empty if macOS will not say.
pressure_level() { sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null | tr -dc '0-9'; }

# mem_state <swap MB> <pressure>: fine, tight or critical.
# Pressure decides when macOS reports it: swap left on disk after a busy spell is not pressure.
mem_state() {
  case "$2" in
    4) echo critical ;;
    2) echo tight ;;
    1) echo fine ;;
    *) if [ "$1" -ge "$SWAP_CRIT_MB" ]; then echo critical
       elif [ "$1" -ge "$SWAP_WARN_MB" ]; then echo tight; else echo fine; fi ;;
  esac
}

# Writes MEMFILE: memory by app, helpers added to their parent .app. Uses the footprint
# that Activity Monitor shows (it includes compressed and swapped memory); falls back to
# resident memory from ps when top gives nothing.
memory_snapshot() {
  local raw="$REAPER_DIR/.top.$$" pids="$REAPER_DIR/.ps.$$"
  mkdir -p "$REAPER_DIR"
  ps -axo pid=,rss=,comm= 2>/dev/null > "$pids"
  : > "$raw"
  run_with_timeout 20 top -l 1 -stats pid,mem > "$raw" 2>/dev/null
  awk '
    function mb(v,   u, x) { sub(/[+-]+$/, "", v); u = substr(v, length(v)); x = substr(v, 1, length(v) - 1) + 0
      return u == "G" ? x * 1024 : u == "M" ? x : u == "K" ? x / 1024 : u == "B" ? x / 1048576 : -1 }
    FILENAME == ARGV[1] {
      if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+[BKMG][+-]*$/) { foot[$1] = mb($2); have = 1 }
      next }
    { pid = $1; rss = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); n = split($0, p, "/"); name = p[n]
      for (i = 1; i <= n; i++) if (p[i] ~ /\.app$/) { name = p[i]; sub(/\.app$/, "", name); break }
      if (have) { if (pid in foot) sum[name] += foot[pid] } else sum[name] += rss / 1024 }
    END { for (k in sum) if (sum[k] >= 1) printf "%d\t%s\n", sum[k], k }' "$raw" "$pids" |
    sort -rn > "$MEMFILE.tmp" && mv "$MEMFILE.tmp" "$MEMFILE"
  rm -f "$raw" "$pids"
}

# "MB<TAB>app" lines, biggest first, from the latest snapshot.
top_memory_lines() {
  [ -s "$MEMFILE" ] || memory_snapshot
  head -n "${1:-5}" "$MEMFILE" 2>/dev/null
}

top_memory() {
  top_memory_lines "${1:-4}" | awk -F'\t' '{printf "%s%s %d MB", (NR>1 ? ", " : ""), $2, $1}'
}

run_with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local killer=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  return $rc
}

# stamp_due <kind> <minutes>: true, and restamps, if <minutes> have passed since the last time.
stamp_due() {
  local f="$REAPER_DIR/.stamp-$1" now last
  now=$(date +%s); last=$(cat "$f" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge $(( $2 * 60 )) ] || return 1
  [ "$DRY_RUN" = 1 ] || echo "$now" > "$f"
  return 0
}

# snoozed: true while warnings are snoozed; sets SNOOZE_LABEL to when they resume.
snoozed() {
  local end now
  SNOOZE_LABEL=""
  [ -f "$SNOOZE" ] || return 1
  IFS="$TAB" read -r end SNOOZE_LABEL < "$SNOOZE"
  case "$end" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -lt "$end" ]
}

do_snooze() {  # do_snooze <minutes>; 0 resumes
  local min="${1:-60}" label
  case "$min" in ''|*[!0-9]*) echo "usage: --snooze <minutes>   (0 to resume)"; exit 2 ;; esac
  mkdir -p "$REAPER_DIR"
  if [ "$min" -eq 0 ]; then
    rm -f "$SNOOZE"; log "snooze ended"
  else
    label=$(date -v+"${min}"M '+%a %H:%M' 2>/dev/null || date -d "+${min} minutes" '+%a %H:%M' 2>/dev/null)
    printf '%s\t%s\n' "$(( $(date +%s) + min * 60 ))" "$label" > "$SNOOZE"
    log "warnings snoozed until $label"
  fi
}

# notify <kind> <title> <message>; repeats of one kind are rate-limited.
# While snoozed only the critical kinds (disk-crit, swap-crit) are shown; the rest are logged.
notify() {
  local title="$2" msg; msg="$(clean "$3")"
  stamp_due "notify-$1" "$NOTIFY_EVERY_MIN" || return 0
  if snoozed; then
    case "$1" in *-crit) ;; *) log "snoozed, not shown: [$title] $msg"; return 0 ;; esac
  fi
  log "NOTIFY [$title] $msg"
  [ "$DRY_RUN" = 1 ] && return 0
  /usr/bin/osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Basso\"" >/dev/null 2>&1
}

# confirm_dialog <message> <ok button>: true only if you press the ok button.
# In <message>, the two characters \n are a line break; everything else must be clean()ed.
confirm_dialog() {
  local msg="$1" ok="$2" out
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ "$DRY_RUN" = 1 ]; then log "would ask: $msg"; return 1; fi
  out=$(/usr/bin/osascript -e "display dialog \"$msg\" with title \"Mac Reaper\" buttons {\"Not now\", \"$ok\"} default button \"Not now\" cancel button \"Not now\" with icon caution giving up after $DIALOG_TIMEOUT_SEC" 2>/dev/null)
  case "$out" in *"button returned:$ok"*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------- lock

acquire_lock() {
  local lock="$REAPER_DIR/.lock" started now
  mkdir -p "$REAPER_DIR"
  if ! mkdir "$lock" 2>/dev/null; then
    started=$(cat "$lock/started" 2>/dev/null); now=$(date +%s)
    case "$started" in ''|*[!0-9]*) started=0 ;; esac
    [ $((now - started)) -lt 1800 ] && return 1
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 1
  fi
  date +%s > "$lock/started"
  LOCK_HELD=1
  trap 'release_lock; rm -f "$REAPER_DIR"/.*.$$ 2>/dev/null' EXIT
}

acquire_lock_wait() {
  local tries=$(( ${1:-60} / 2 ))
  while ! acquire_lock; do
    tries=$((tries - 1)); [ "$tries" -le 0 ] && return 1
    sleep 2
  done
}

release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then rm -rf "$REAPER_DIR/.lock"; LOCK_HELD=0; fi
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  if [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 524288 ]; then
    tail -n 1500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# ---------------------------------------------------------------- what is open right now

running_snapshot() {
  RUN_TABLE=$(lsappinfo list 2>/dev/null | awk '
    /^ *[0-9]+\) "/ { n = $0; sub(/^[^"]*"/, "", n); sub(/".*$/, "", n) }
    /bundleID="/    { b = $0; sub(/.*bundleID="/, "", b); sub(/".*/, "", b)
                      if (b != "") print tolower(b) "\t" n }')
  RUN_IDS=$(printf '%s\n' "$RUN_TABLE" | cut -f1 | grep -v '^$' | sort -u)
  RUN_WORDS=$(printf '%s\n' "$RUN_IDS" | tr '.' '\n' | awk 'length($0) >= 3' |
    grep -vxE 'com|org|net|app|apple|www|desktop|mac|macos|helper|client|inc' | sort -u)
}

app_name() {
  printf '%s\n' "$RUN_TABLE" | awk -F'\t' -v id="$1" '$1 == id { print $2; found = 1; exit } END { if (!found) print id }'
}

app_running() { printf '%s\n' "$RUN_IDS" | grep -qx "$1"; }

# Prints the name of the open app (or running tool) that owns a ~/Library/Caches folder, if any.
cache_owner() {
  local n id w
  n=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  for id in $RUN_IDS; do
    case "$n" in "$id"|"$id".*) app_name "$id"; return 0 ;; esac
    case "$id" in "$n".*) app_name "$id"; return 0 ;; esac
  done
  for w in $RUN_WORDS; do
    [ "$n" = "$w" ] || continue
    for id in $RUN_IDS; do
      case ".$id." in *".$w."*) app_name "$id"; return 0 ;; esac
    done
  done
  case "$n" in
    homebrew) pgrep -f 'Library/Homebrew' >/dev/null 2>&1 && echo "Homebrew" ;;
    pip)      pgrep -f 'pip3? install' >/dev/null 2>&1 && echo "pip" ;;
    go-build) pgrep -x go >/dev/null 2>&1 && echo "go" ;;
  esac
  return 0
}

kept() { case ":$KEEP_CACHES:" in *":$1:"*) return 0 ;; esac; return 1; }

docker_ready() { command -v docker >/dev/null 2>&1 && run_with_timeout 8 docker info >/dev/null 2>&1; }

xcode_selected() { case "$(xcode-select -p 2>/dev/null)" in *Xcode*.app*) return 0 ;; esac; return 1; }

path_of() {
  case "$1" in
    derived)    echo "$HOME/Library/Developer/Xcode/DerivedData" ;;
    devsupport) echo "$HOME/Library/Developer/Xcode/iOS DeviceSupport" ;;
    simcache)   echo "$HOME/Library/Developer/CoreSimulator/Caches" ;;
    npm)        echo "$HOME/.npm/_cacache" ;;
    gradle)     echo "$HOME/.gradle/caches" ;;
    maven)      echo "$HOME/.m2/repository" ;;
    dotcache)   echo "$HOME/.cache" ;;
  esac
}

# ---------------------------------------------------------------- scan: what could be cleared

add_cand() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(clean "$4")" "$(clean "$5")" >> "$CAND_TMP"; }

cand_dir() {  # cand_dir <id> <label> <reason or -> ; a reason makes it "needs your OK"
  local id="$1" label="$2" reason="$3" dir kb
  dir=$(path_of "$id"); [ -d "$dir" ] || return 0
  kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}'); kb=${kb:-0}
  [ "$kb" -ge "$MIN_KB" ] || return 0
  if [ "$reason" = "-" ]; then add_cand "$id" auto "$kb" "$label" "-"
  else add_cand "$id" confirm "$kb" "$label" "$reason"; fi
}

scan_caches() {
  local root="$HOME/Library/Caches" list="$REAPER_DIR/.du.$$" kb path name owner idle=0 open=0 apps
  : > "$CACHES.tmp"
  [ -d "$root" ] || { mv "$CACHES.tmp" "$CACHES"; return 0; }
  du -sk "$root"/* "$root"/.[!.]* 2>/dev/null > "$list"
  while IFS="$TAB" read -r kb path; do
    name=${path##*/}
    [ -n "$name" ] || continue
    kept "$name" && continue
    owner=$(cache_owner "$name")
    if [ -n "$owner" ]; then open=$((open + kb)); else idle=$((idle + kb)); owner="-"; fi
    printf '%s\t%s\t%s\n' "$kb" "$(clean "$owner")" "$(clean "$name")" >> "$CACHES.tmp"
  done < "$list"
  rm -f "$list"
  sort -rn "$CACHES.tmp" > "$CACHES"; rm -f "$CACHES.tmp"
  apps=$(awk -F'\t' '$2 != "-" && !seen[$2]++ { n++; if (n <= 4) s = s (s ? ", " : "") $2 }
                     END { if (n > 4) s = s " and " (n - 4) " more"; print s }' "$CACHES")
  if [ "$idle" -ge "$MIN_KB" ]; then add_cand caches-idle auto "$idle" "App caches (apps not open)" "-"; fi
  if [ "$open" -ge "$MIN_KB" ]; then add_cand caches-open confirm "$open" "Caches of open apps" "open now: $apps"; fi
}

scan() {
  local why kb
  mkdir -p "$REAPER_DIR"
  CAND_TMP="$REAPER_DIR/.cand.$$"; : > "$CAND_TMP"
  running_snapshot

  why="-"
  if app_running com.apple.dt.xcode || pgrep -x xcodebuild >/dev/null 2>&1; then why="Xcode is open"; fi
  cand_dir derived "Xcode build data" "$why"
  cand_dir devsupport "iOS device support files" "$why"
  why="-"; app_running com.apple.iphonesimulator && why="Simulator is open"
  cand_dir simcache "Simulator caches" "$why"
  why="-"; pgrep -x npm >/dev/null 2>&1 && why="npm is running"
  cand_dir npm "npm download cache" "$why"

  scan_caches

  why="re-downloaded on the next build"
  pgrep -f GradleDaemon >/dev/null 2>&1 && why="Gradle is running"
  cand_dir gradle "Gradle caches" "$why"
  why="re-downloaded on the next build"
  pgrep -f 'plexus-classworlds|maven-wrapper' >/dev/null 2>&1 && why="Maven is running"
  cand_dir maven "Maven repository" "$why"
  cand_dir dotcache "Tool caches in ~/.cache" "may hold downloaded models and tool environments"

  if docker_ready; then
    add_cand docker-images auto -1 "Dangling Docker images" "-"
    add_cand docker-build confirm -1 "Docker build cache" "slows the next image build"
  fi
  if command -v brew >/dev/null 2>&1; then
    if pgrep -f 'Library/Homebrew' >/dev/null 2>&1; then
      add_cand brew confirm -1 "Old Homebrew downloads and versions" "Homebrew is running"
    else
      add_cand brew auto -1 "Old Homebrew downloads and versions" "-"
    fi
  fi
  if xcode_selected; then add_cand simulators auto -1 "Unavailable iOS simulators" "-"; fi
  if [ "$TRASH_MAX_AGE_DAYS" -gt 0 ] 2>/dev/null && ls "$HOME/.Trash" >/dev/null 2>&1; then
    kb=$(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -mtime +"$TRASH_MAX_AGE_DAYS" -exec du -sk {} + 2>/dev/null | awk '{s += $1} END {print s + 0}')
    if [ "$kb" -ge "$MIN_KB" ]; then
      add_cand trash-old confirm "$kb" "Trash items older than $TRASH_MAX_AGE_DAYS days" "your deleted files, gone for good"
    fi
  fi

  mv "$CAND_TMP" "$CAND"
  scan_large
  date +%s > "$REAPER_DIR/.stamp-scan"
}

# Big things the reaper never touches, listed in the report so nothing hides. Only places a
# background job can read without macOS asking for permission.
large_item() {  # large_item <path> <label> <what you can do>
  local kb
  [ -e "$1" ] || return 0
  kb=$(run_with_timeout 20 du -sk "$1" 2>/dev/null | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$kb" -ge 512000 ] || return 0
  printf '%s\t%s\t%s\n' "$kb" "$2" "$3" >> "$LARGE.tmp"
}

scan_large() {
  : > "$LARGE.tmp"
  large_item "$HOME/.colima" "colima virtual machine disk" "shrinks only if recreated: colima delete, then colima start"
  large_item "$HOME/.ollama/models" "Ollama models" "remove one with: ollama rm MODEL"
  large_item "$HOME/Library/Developer/CoreSimulator/Devices" "iOS simulators" "delete unused ones in Xcode, or all with: xcrun simctl delete all"
  large_item "/Library/Developer/CoreSimulator" "iOS simulator runtimes" "remove in Xcode, Settings, Components"
  large_item "$HOME/Library/Developer/Xcode/Archives" "Xcode archives" "delete old ones in Xcode, Organizer"
  large_item "$HOME/Library/Application Support/Claude" "Claude desktop app data" "see Storage in the Claude app settings"
  large_item "/Library/Application Support/Logi/LogiOptionsPlus/depots" "Logitech Options+ update copies" "old copies need sudo to delete"
  large_item "$HOME/.pyenv/versions" "pyenv Python versions" "remove one with: pyenv uninstall VERSION"
  large_item "$HOME/go/pkg/mod" "Go module cache" "clear with: go clean -modcache"
  sort -rn "$LARGE.tmp" > "$LARGE"; rm -f "$LARGE.tmp"
}

scan_due() {
  local now last; now=$(date +%s); last=$(cat "$REAPER_DIR/.stamp-scan" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ ! -f "$CAND" ] || [ $((now - last)) -ge $((SCAN_EVERY_MIN * 60)) ]
}

# sum_class <class>: sets SUM_KB (known sizes only) and SUM_N
sum_class() {
  SUM_KB=0; SUM_N=0; [ -f "$CAND" ] || return 0
  set -- $(awk -F'\t' -v c="$1" '$2 == c { n++; if ($3 > 0) s += $3 } END { printf "%d %d", s, n }' "$CAND")
  SUM_KB=${1:-0}; SUM_N=${2:-0}
}

# ---------------------------------------------------------------- deleting

wipe_dir() {  # empties a directory under $HOME, keeps the directory; sets FREED_KB
  local dir="$1" before after
  FREED_KB=0
  case "$dir" in "$HOME"/?*) ;; *) log "skip (outside home): $dir"; return 1 ;; esac
  [ -d "$dir" ] || return 1
  [ -L "$dir" ] && { log "skip (symlink): $dir"; return 1; }
  before=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  after=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  FREED_KB=$(( ${before:-0} - ${after:-0} )); [ "$FREED_KB" -lt 0 ] && FREED_KB=0
  return 0
}

wipe_caches() {  # wipe_caches idle|open ; "open" = folders whose app is open right now
  local mode="$1" root="$HOME/Library/Caches" d name owner before after
  FREED_KB=0
  [ -d "$root" ] || return 1
  [ -L "$root" ] && return 1
  running_snapshot
  for d in "$root"/* "$root"/.[!.]*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    name=${d##*/}
    kept "$name" && continue
    owner=$(cache_owner "$name")
    if [ "$mode" = idle ] && [ -n "$owner" ]; then continue; fi
    if [ "$mode" = open ] && [ -z "$owner" ]; then continue; fi
    before=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    rm -rf "$d" 2>/dev/null
    after=0; [ -e "$d" ] && after=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    FREED_KB=$(( FREED_KB + ${before:-0} - ${after:-0} ))
  done
  [ "$FREED_KB" -lt 0 ] && FREED_KB=0
  return 0
}

run_action() {  # commands whose result is measured by the change in free space
  local before after
  before=$(free_kb)
  case "$1" in
    docker-images) docker_ready && run_with_timeout 120 docker image prune -f >/dev/null 2>&1 ;;
    docker-build)  docker_ready && run_with_timeout 120 docker builder prune -f >/dev/null 2>&1 ;;
    brew)          HOMEBREW_NO_AUTO_UPDATE=1 run_with_timeout 180 brew cleanup -s >/dev/null 2>&1 ;;
    simulators)    xcode_selected && run_with_timeout 60 xcrun simctl delete unavailable >/dev/null 2>&1 ;;
    trash-old)     find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -mtime +"$TRASH_MAX_AGE_DAYS" -exec rm -rf {} + 2>/dev/null ;;
  esac
  after=$(free_kb)
  FREED_KB=$((after - before)); [ "$FREED_KB" -lt 0 ] && FREED_KB=0
  return 0
}

do_delete() {  # do_delete <id> <how> <label>
  local id="$1" how="$2" label="$3"
  FREED_KB=0
  if [ "$DRY_RUN" = 1 ]; then log "would clear: $label"; return 0; fi
  case "$id" in
    derived|devsupport|simcache|npm|gradle|maven|dotcache) wipe_dir "$(path_of "$id")" || return 1 ;;
    caches-idle) wipe_caches idle || return 1 ;;
    caches-open) wipe_caches open || return 1 ;;
    docker-images|docker-build|brew|simulators|trash-old) run_action "$id" ;;
    *) log "unknown item: $id"; return 1 ;;
  esac
  if [ "$FREED_KB" -gt 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$how" "$FREED_KB" "$id" "$label" >> "$HIST"
  fi
  log "cleared ($how): $label, freed $(human "$FREED_KB")"
  return 0
}

# clean_class <class> <how>: clears every candidate of that class; sets CLEANED_KB, CLEANED_N
clean_class() {
  local want="$1" how="$2" todo="$REAPER_DIR/.todo.$$" id class kb label reason
  CLEANED_KB=0; CLEANED_N=0
  [ -f "$CAND" ] || return 0
  cp "$CAND" "$todo"
  while IFS="$TAB" read -r id class kb label reason <&3; do
    [ "$class" = "$want" ] || continue
    # size-unknown commands (brew, docker, simulators) run at most every 6 hours when unattended
    if [ "$how" = auto ] && [ "$kb" -lt 0 ] && ! stamp_due "cmd-$id" 360; then continue; fi
    do_delete "$id" "$how" "$label" || continue
    CLEANED_KB=$((CLEANED_KB + FREED_KB)); CLEANED_N=$((CLEANED_N + 1))
  done 3< "$todo"
  rm -f "$todo"
}

# pending_text: the "needs your OK" items as dialog lines (\n separated)
pending_text() {
  awk -F'\t' '$2 == "confirm" {
    size = ($3 < 0) ? "size unknown" : ($3 < 1048576 ? sprintf("%d MB", $3/1024) : sprintf("%.1f GB", $3/1048576))
    printf "- %s, %s%s\\n", $4, size, ($5 != "-" ? " (" $5 ")" : "")
  }' "$CAND"
}

ask_pending() {  # scheduled run, disk low: one dialog for everything that needs an OK
  sum_class confirm
  [ "$SUM_N" -gt 0 ] || return 0
  [ "$SUM_KB" -ge $((ASK_MIN_MB * 1024)) ] || return 0
  snoozed && return 0
  stamp_due ask "$NOTIFY_EVERY_MIN" || return 0
  local msg
  msg="Disk is ${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free.\n\nThese can be cleared, but each may affect something in use:\n\n$(pending_text)\nClear them all now? To pick single items, use the menu bar icon."
  release_lock
  if confirm_dialog "$msg" "Clear all"; then
    acquire_lock_wait 60 || return 0
    clean_class confirm approved
    ASKED_KB=$CLEANED_KB
  else
    [ "$DRY_RUN" = 1 ] || log "asked about $SUM_N items ($(human "$SUM_KB")): not now"
    acquire_lock_wait 60 || return 0
  fi
}

check_memory() {  # check_memory <swap MB> <pressure level>
  local swap="$1" state top prev rise=""
  [ -n "$swap" ] || return 0
  state=$(mem_state "$swap" "${2:-}")
  prev=$(cat "$REAPER_DIR/.last-swap" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=$swap ;; esac
  [ "$DRY_RUN" = 1 ] || echo "$swap" > "$REAPER_DIR/.last-swap"
  [ $((swap - prev)) -ge "$SWAP_RISE_MB" ] && rise=" and rising"
  top="$(top_memory 4)"
  if [ "$state" = critical ] || [ "$swap" -ge "$SWAP_CRIT_MB" ]; then
    if [ "$AUTO_STOP_COLIMA" = 1 ] && command -v colima >/dev/null 2>&1 && run_with_timeout 15 colima status >/dev/null 2>&1; then
      if [ "$DRY_RUN" = 1 ]; then log "would stop colima"; else
        run_with_timeout 120 colima stop >/dev/null 2>&1 && log "stopped colima (swap ${swap} MB)"
      fi
      notify swap-crit "Mac Reaper: memory critical" "Swap ${swap} MB${rise}. Stopped colima. Close apps now: $top"
    else
      notify swap-crit "Mac Reaper: memory critical" "Swap ${swap} MB${rise}. Close apps now or the Mac may freeze: $top"
    fi
  elif [ "$swap" -ge "$SWAP_WARN_MB" ] && { [ "$state" = tight ] || [ -n "$rise" ]; }; then
    notify swap-warn "Mac Reaper: memory is tight" "Swap ${swap} MB${rise}. Biggest: $top"
  fi
}

# ---------------------------------------------------------------- the scheduled check

finish() {  # refresh the things the menu and report read
  write_report 2>/dev/null
  render_menu > "$REAPER_DIR/last-menu.txt" 2>/dev/null
  return 0
}

run_check() {
  acquire_lock || exit 0
  rotate_log
  local swap low=0 auto_kb=0 more level
  ASKED_KB=0
  disk_read; swap=$(swap_used_mb); level=$(pressure_level)
  [ "$DISK_TOTAL_KB" -gt 0 ] || { log "could not read free disk space"; exit 1; }
  log "check: ${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free, swap ${swap:-?} MB, memory $(mem_state "${swap:-0}" "$level") (pressure ${level:-unknown})"
  [ "$DRY_RUN" = 1 ] || date +%s > "$REAPER_DIR/.stamp-check"
  memory_snapshot
  if [ "$FORCE" = 1 ] || is_low; then low=1; fi

  if [ "$low" = 1 ] || scan_due; then scan; fi

  if [ "$low" = 1 ]; then
    clean_class auto auto; auto_kb=$CLEANED_KB
    disk_read
    ask_pending
    if [ "$DRY_RUN" = 0 ]; then
      scan; disk_read
      log "clean-up done: freed $(human $((auto_kb + ASKED_KB))), now ${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free"
      sum_class confirm
      if is_crit; then
        notify disk-crit "Mac Reaper: disk almost full" "${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free after clearing $(human $((auto_kb + ASKED_KB))). Close heavy apps or restart."
      elif is_low; then
        more=""; [ "$SUM_KB" -ge $((ASK_MIN_MB * 1024)) ] && more=" $(human "$SUM_KB") more needs your OK in the menu bar."
        notify disk-low "Mac Reaper: disk is low" "${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free. Cleared $(human $((auto_kb + ASKED_KB))).$more"
      fi
    fi
  fi
  check_memory "$swap" "$level"
  [ "$DRY_RUN" = 1 ] || finish
}

# ---------------------------------------------------------------- actions from the menu

lookup() { awk -F'\t' -v id="$1" '$1 == id { print; exit }' "$CAND" 2>/dev/null; }

do_approve() {
  local want="${1:-}" line id class kb label reason how=manual
  [ -n "$want" ] || { echo "usage: --approve <item>"; exit 2; }
  acquire_lock_wait 60 || { echo "busy, try again in a minute"; exit 1; }
  line=$(lookup "$want"); [ -n "$line" ] || { scan; line=$(lookup "$want"); }
  [ -n "$line" ] || { echo "nothing to clear for: $want"; finish; exit 0; }
  IFS="$TAB" read -r id class kb label reason <<EOF
$line
EOF
  if [ "$class" = confirm ]; then
    how=approved
    release_lock
    if ! confirm_dialog "Clear $label ($(human "$kb"))?\n\nWhy it asks: $reason." "Clear"; then
      log "not cleared (you said not now): $label"; exit 0
    fi
    acquire_lock_wait 60 || exit 1
  fi
  do_delete "$id" "$how" "$label"
  scan; finish
}

do_approve_all() {
  acquire_lock_wait 60 || { echo "busy, try again in a minute"; exit 1; }
  scan; sum_class confirm
  [ "$SUM_N" -gt 0 ] || { echo "nothing is waiting for your OK"; finish; exit 0; }
  release_lock
  if ! confirm_dialog "Clear all of these?\n\n$(pending_text)" "Clear all"; then
    log "not cleared (you said not now): $SUM_N items"; exit 0
  fi
  acquire_lock_wait 60 || exit 1
  clean_class confirm approved
  scan; finish
}

do_clean_safe() {
  acquire_lock_wait 60 || { echo "busy, try again in a minute"; exit 1; }
  scan
  clean_class auto manual
  log "manual clean-up of safe items: freed $(human "$CLEANED_KB")"
  scan; finish
}

do_scan() {
  acquire_lock_wait 60 || { echo "busy, try again in a minute"; exit 1; }
  scan; finish
}

# ---------------------------------------------------------------- SwiftBar menu

totals() {
  TODAY_KB=0; WEEK_KB=0; ALL_KB=0
  [ -f "$HIST" ] || return 0
  local today cutoff
  today=$(date '+%Y-%m-%d')
  cutoff=$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || echo "$today")
  set -- $(awk -F'\t' -v t="$today" -v c="$cutoff" '{ d = substr($1, 1, 10); a += $3
              if (d == t) x += $3; if (d >= c) w += $3 } END { printf "%d %d %d", x, w, a }' "$HIST")
  TODAY_KB=${1:-0}; WEEK_KB=${2:-0}; ALL_KB=${3:-0}
}

act() { printf 'bash="%s" param1=%s%s terminal=false refresh=true' "$SELF" "$1" "${2:+ param2=$2}"; }

render_menu() {
  local swap title color="" mem id class kb label reason n when how last age
  disk_read; swap=$(swap_used_mb); swap=${swap:-0}; totals
  title="${DISK_PCT}%"
  if [ "$TODAY_KB" -ge 102400 ]; then title="$title  ↓$(human "$TODAY_KB")"; fi
  if snoozed; then title="$title  zz"; fi
  if is_crit; then color=" color=#FF453A"; elif is_low; then color=" color=#FF9F0A"; fi
  echo "$title | templateImage=$ICON$color"
  echo "---"
  echo "Disk ${DISK_PCT}% full · $(gb "$DISK_FREE_KB") GB free of $(gb "$DISK_TOTAL_KB") GB | $(act --report)"
  mem=$(mem_state "$swap" "$(pressure_level)")
  if [ "$mem" = fine ] && [ "$swap" -ge "$SWAP_WARN_MB" ]; then
    echo "Memory fine now · $(human $((swap * 1024))) still in swap | $(act --report)"
  else
    echo "Memory $mem · swap $(human $((swap * 1024))) | $(act --report)"
  fi
  if [ -s "$MEMFILE" ]; then
    head -n 6 "$MEMFILE" | while IFS="$TAB" read -r kb label; do echo "--$(clean "$label") · $(human $((kb * 1024)))"; done
  fi
  if command -v colima >/dev/null 2>&1 && pgrep -f 'limactl' >/dev/null 2>&1; then
    echo "--Stop colima to free memory | bash=\"$(command -v colima)\" param1=stop terminal=false refresh=true"
  fi
  echo "---"
  echo "Cleared today $(human "$TODAY_KB") · 7 days $(human "$WEEK_KB") · all time $(human "$ALL_KB") | $(act --report)"
  if [ -s "$HIST" ]; then
    tail -n 12 "$HIST" | awk -F'\t' '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }' |
    while IFS="$TAB" read -r when how kb id label; do
      echo "--$when · $label · $(human "$kb")"
    done
  else
    echo "--Nothing cleared yet"
  fi
  echo "---"
  if [ -s "$CAND" ]; then
    sum_class confirm
    if [ "$SUM_N" -gt 0 ]; then
      echo "Needs your OK · $(human "$SUM_KB") | size=12"
      while IFS="$TAB" read -r id class kb label reason; do
        [ "$class" = confirm ] || continue
        echo "$label · $(human "$kb") · $reason | $(act --approve "$id")"
      done < "$CAND"
      echo "Clear all of these… | $(act --approve-all)"
      echo "---"
    fi
    sum_class auto
    if [ "$SUM_N" -gt 0 ]; then
      echo "Safe to clear · $(human "$SUM_KB") | size=12"
      n=0
      while IFS="$TAB" read -r id class kb label reason; do
        [ "$class" = auto ] || continue
        if [ "$kb" -lt 0 ]; then n=$((n + 1)); continue; fi
        echo "$label · $(human "$kb") | $(act --approve "$id")"
      done < "$CAND"
      if [ "$n" -gt 0 ]; then echo "Clear all safe items now, plus $n clean-up commands | $(act --clean-safe)"
      else echo "Clear all safe items now | $(act --clean-safe)"; fi
      echo "---"
    fi
  else
    echo "Nothing to clear right now"
    echo "---"
  fi
  if snoozed; then
    echo "Warnings snoozed until $SNOOZE_LABEL · click to resume | $(act --snooze 0)"
  else
    echo "Snooze warnings"
    echo "--For 1 hour | $(act --snooze 60)"
    echo "--For 4 hours | $(act --snooze 240)"
    echo "--For 24 hours | $(act --snooze 1440)"
  fi
  last=$(cat "$REAPER_DIR/.stamp-check" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) ;; *)
    age=$(( ($(date +%s) - last) / 60 ))
    if [ "$age" -lt 1 ]; then echo "Last background check just now | size=12"
    elif [ "$age" -lt 120 ]; then echo "Last background check $age min ago | size=12"
    else echo "Last background check $((age / 60)) hours ago | size=12"; fi ;;
  esac
  echo "---"
  echo "Full report | $(act --report)"
  echo "Rescan now | $(act --scan)"
  echo "Settings | bash=/usr/bin/open param1=-t param2=\"$REAPER_DIR/config\" terminal=false"
  echo "Log | bash=/usr/bin/open param1=-t param2=\"$LOG\" terminal=false"
}

# ---------------------------------------------------------------- report

write_report() {
  local swap id class kb label reason level
  disk_read; swap=$(swap_used_mb); level=$(pressure_level); totals
  {
    cat <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Mac Reaper report</title>
<style>
:root{--bg:#f6f6f4;--fg:#1c1c1e;--mut:#6b6b70;--card:#fff;--line:#e3e3e0;--ok:#2e8b57;--warn:#c77700;--bad:#c0392b}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f2f2f0;--mut:#a0a0a6;--card:#2a2a2d;--line:#3a3a3e}}
body{font:14px/1.5 -apple-system,sans-serif;background:var(--bg);color:var(--fg);max-width:820px;margin:32px auto;padding:0 16px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:28px 0 8px}.mut{color:var(--mut)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
.bar{height:14px;border-radius:7px;background:var(--line);overflow:hidden;margin:10px 0}.bar i{display:block;height:100%}
table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--mut);font-size:12px}td.n,th.n{text-align:right;white-space:nowrap}
.big{font-size:28px;font-weight:600}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
</style></head><body>
<h1>Mac Reaper report</h1><div class="mut">$(date '+%A %e %B %Y, %H:%M') · version $VERSION</div>
<h2>Disk</h2><div class="card"><span class="big">${DISK_PCT}% full</span>
<div class="bar"><i style="width:${DISK_PCT}%;background:var(--$(if is_crit; then echo bad; elif is_low; then echo warn; else echo ok; fi))"></i></div>
$(gb "$DISK_FREE_KB") GB free of $(gb "$DISK_TOTAL_KB") GB. Cleans by itself below $WARN_FREE_GB GB free; urgent below $CRIT_FREE_GB GB.<br>
Memory is $(mem_state "${swap:-0}" "$level"). Swap in use: ${swap:-?} MB (warns at $SWAP_WARN_MB MB under pressure or when rising, critical at $SWAP_CRIT_MB MB).</div>
<h2>Cleared so far</h2><div class="grid">
<div class="card"><div class="mut">Today</div><div class="big">$(human "$TODAY_KB")</div></div>
<div class="card"><div class="mut">Last 7 days</div><div class="big">$(human "$WEEK_KB")</div></div>
<div class="card"><div class="mut">All time</div><div class="big">$(human "$ALL_KB")</div></div></div>
<h2>Could clear now</h2><div class="card"><table><tr><th>Item</th><th class="n">Size</th><th>Handling</th><th>Why it would ask</th></tr>
HTML
    if [ -s "$CAND" ]; then
      while IFS="$TAB" read -r id class kb label reason; do
        [ "$reason" = "-" ] && reason=""
        if [ "$class" = auto ]; then class="clears by itself when disk is low"; else class="waits for your OK"; fi
        printf '<tr><td>%s</td><td class="n">%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(printf '%s' "$label" | html)" "$(human "$kb")" "$class" "$(printf '%s' "$reason" | html)"
      done < "$CAND"
    else
      echo '<tr><td colspan="4" class="mut">Nothing worth clearing right now.</td></tr>'
    fi
    echo '</table></div><h2>What was deleted</h2><div class="card"><table><tr><th>When</th><th>Item</th><th class="n">Freed</th><th>How</th></tr>'
    if [ -s "$HIST" ]; then
      tail -n 60 "$HIST" | awk -F'\t' '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }' |
      while IFS="$TAB" read -r id class kb label reason; do
        # history columns: when, how, KB, id, label
        case "$class" in auto) class="by itself" ;; approved) class="after your OK" ;; manual) class="from the menu" ;; esac
        printf '<tr><td>%s</td><td>%s</td><td class="n">%s</td><td>%s</td></tr>\n' \
          "$id" "$(printf '%s' "$reason" | html)" "$(human "$kb")" "$class"
      done
    else
      echo '<tr><td colspan="4" class="mut">Nothing has been deleted yet.</td></tr>'
    fi
    echo '</table></div><h2>Largest app caches</h2><div class="card"><table><tr><th>Folder in ~/Library/Caches</th><th class="n">Size</th><th>App open now</th></tr>'
    if [ -s "$CACHES" ]; then
      head -n 15 "$CACHES" | while IFS="$TAB" read -r kb label id; do
        [ "$label" = "-" ] && label=""
        printf '<tr><td>%s</td><td class="n">%s</td><td>%s</td></tr>\n' \
          "$(printf '%s' "$id" | html)" "$(human "$kb")" "$(printf '%s' "$label" | html)"
      done
    fi
    echo '</table></div><h2>Biggest memory users</h2><div class="card"><table><tr><th>App</th><th class="n">Memory</th></tr>'
    top_memory_lines 8 | while IFS="$TAB" read -r kb label; do
      printf '<tr><td>%s</td><td class="n">%s</td></tr>\n' "$(printf '%s' "$label" | html)" "$(human $((kb * 1024)))"
    done
    echo '</table></div><h2>Large items it leaves alone</h2><div class="card"><table><tr><th>Item</th><th class="n">Size</th><th>What you can do</th></tr>'
    if [ -s "$LARGE" ]; then
      while IFS="$TAB" read -r kb label reason; do
        printf '<tr><td>%s</td><td class="n">%s</td><td>%s</td></tr>\n' \
          "$(printf '%s' "$label" | html)" "$(human "$kb")" "$(printf '%s' "$reason" | html)"
      done < "$LARGE"
    else
      echo '<tr><td colspan="3" class="mut">Nothing over 500 MB in the places it checks.</td></tr>'
    fi
    echo "</table></div><p class=\"mut\">Settings: $REAPER_DIR/config · Log: $LOG</p></body></html>"
  } > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
}

do_report() {
  if scan_due && acquire_lock; then scan; release_lock; fi
  write_report
  if [ -t 1 ]; then echo "Report: $REPORT"; fi
  open "$REPORT" >/dev/null 2>&1
  return 0
}

do_status() {
  local swap id class kb label reason level
  disk_read; swap=$(swap_used_mb); level=$(pressure_level); totals
  memory_snapshot
  echo "Disk:       ${DISK_PCT}% full, $(gb "$DISK_FREE_KB") GB free of $(gb "$DISK_TOTAL_KB") GB   (acts below $WARN_FREE_GB GB free)"
  echo "Memory:     $(mem_state "${swap:-0}" "$level") (pressure ${level:-unknown}), swap ${swap:-?} MB"
  if snoozed; then echo "Warnings:   snoozed until $SNOOZE_LABEL"; fi
  echo "Top memory: $(top_memory 5)"
  echo "Cleared:    today $(human "$TODAY_KB"), last 7 days $(human "$WEEK_KB"), all time $(human "$ALL_KB")"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then echo "Schedule:   installed"; else echo "Schedule:   not installed"; fi
  if [ -n "$(plugin_dir)" ] && [ -f "$(plugin_dir)/$PLUGIN_NAME" ]; then echo "SwiftBar:   plugin installed"; else echo "SwiftBar:   plugin not installed"; fi
  if [ -s "$CAND" ]; then
    echo "--- could clear now ---"
    while IFS="$TAB" read -r id class kb label reason; do
      if [ "$class" = auto ]; then class="safe"; reason=""; else class="needs OK"; fi
      printf '%-10s %12s  %s%s\n' "$class" "$(human "$kb")" "$label" "${reason:+  ($reason)}"
    done < "$CAND"
  fi
  if [ -f "$LOG" ]; then echo "--- last log lines ---"; tail -n 6 "$LOG"; fi
}

# ---------------------------------------------------------------- install

plugin_dir() {
  local d; d=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null)
  d=${d/#\~/$HOME}
  printf '%s' "$d"
}

do_install_plugin() {
  local dir="${1:-}"
  [ -n "$dir" ] || dir=$(plugin_dir)
  dir=${dir/#\~/$HOME}
  if [ -z "$dir" ]; then
    echo "SwiftBar has no plugin folder yet. To finish:"
    echo "  1. brew install --cask swiftbar"
    echo "  2. open SwiftBar once and choose a plugin folder when it asks"
    echo "  3. bash $SELF --install-plugin"
    return 1
  fi
  mkdir -p "$dir" || return 1
  cat > "$dir/$PLUGIN_NAME" <<PLUG
#!/bin/bash
# <xbar.title>Mac Reaper</xbar.title>
# <xbar.desc>Disk and memory watchdog: what was cleared, what could be, and approvals.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
exec /bin/bash "$SELF" --menu
PLUG
  chmod 755 "$dir/$PLUGIN_NAME"
  xattr -d com.apple.quarantine "$dir/$PLUGIN_NAME" 2>/dev/null
  pgrep -x SwiftBar >/dev/null 2>&1 && open -g "swiftbar://refreshallplugins" >/dev/null 2>&1
  echo "SwiftBar plugin installed: $dir/$PLUGIN_NAME"
}

do_install() {
  local src uid; uid=$(id -u)
  src="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mkdir -p "$REAPER_DIR" "$HOME/Library/LaunchAgents"
  [ "$src" = "$SELF" ] || cp "$src" "$SELF"
  chmod 755 "$SELF"
  xattr -d com.apple.quarantine "$SELF" 2>/dev/null

  if [ ! -f "$REAPER_DIR/config" ]; then
    cat > "$REAPER_DIR/config" <<CONF
# mac-reaper settings. Remove the leading # to change a value.
# After changing INTERVAL_SEC, run: bash ~/.mac-reaper/mac-reaper.sh --install
#WARN_FREE_GB=10        # act when free disk drops below this
#CRIT_FREE_GB=5         # urgent warning below this
#WARN_USED_PCT=0        # also act when the disk is this % full; 0 = off
#SWAP_WARN_MB=4096      # notify when swap in use passes this
#SWAP_CRIT_MB=10240     # urgent notify past this
#SWAP_RISE_MB=1024      # also warn when swap grows this much between two checks
#AUTO_STOP_COLIMA=0     # 1 = stop colima automatically at SWAP_CRIT_MB
#TRASH_MAX_AGE_DAYS=30  # 0 = never touch Trash
#KEEP_CACHES=           # e.g. ms-playwright:JetBrains
#ASK_MIN_MB=200         # only ask for your OK when at least this much is at stake
#DIALOG_TIMEOUT_SEC=120
#SCAN_EVERY_MIN=30
#NOTIFY_EVERY_MIN=60
#INTERVAL_SEC=600
CONF
  fi

  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SELF</string></array>
  <key>StartInterval</key><integer>$INTERVAL_SEC</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$REAPER_DIR/launchd.log</string>
  <key>StandardErrorPath</key><string>$REAPER_DIR/launchd.log</string>
</dict>
</plist>
PL

  launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1
  if launchctl bootstrap "gui/$uid" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null; then
    echo "Background check installed: every $((INTERVAL_SEC / 60)) minutes and at login."
  else
    echo "Files are in place, but launchctl refused to load $PLIST" >&2; exit 1
  fi
  do_install_plugin
  echo "Settings: $REAPER_DIR/config"
  echo "Check it: bash $SELF --status"
}

do_uninstall() {
  local dir
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  dir=$(plugin_dir)
  if [ -n "$dir" ] && [ -f "$dir/$PLUGIN_NAME" ]; then rm -f "$dir/$PLUGIN_NAME"; fi
  echo "Schedule and SwiftBar plugin removed. Script, settings and history are still in $REAPER_DIR."
}

# ---------------------------------------------------------------- command line

CMD="${1:-}"; ARG="${2:-}"
for a in "$@"; do [ "$a" = "--yes" ] && ASSUME_YES=1; done
[ "$ARG" = "--yes" ] && ARG=""

case "$CMD" in
  --install)        do_install ;;
  --install-plugin) do_install_plugin "$ARG" ;;
  --uninstall)      do_uninstall ;;
  --status)         do_status ;;
  --menu)           render_menu ;;
  --report)         do_report ;;
  --scan)           do_scan ;;
  --clean-safe)     do_clean_safe ;;
  --approve)        do_approve "$ARG" ;;
  --approve-all)    do_approve_all ;;
  --snooze)         do_snooze "${ARG:-60}" ;;
  --dry-run)        DRY_RUN=1; FORCE=1; run_check ;;
  --force)          FORCE=1; run_check ;;
  "")               run_check ;;
  *)                sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
