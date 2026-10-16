#!/usr/bin/env bash
# soak_test.sh - run (or attach to) the TX8 vision app for N minutes and sample system metrics.
#
# Usage:
#   soak_test.sh [-m MINUTES] [-i INTERVAL_S] [-o OUT.csv] -- <app command> [args...]
#   soak_test.sh [-m MINUTES] [-i INTERVAL_S] [-o OUT.csv] -p <PID>
#   soak_test.sh --help
#
# Options:
#   -m MINUTES    duration (default 10)
#   -i INTERVAL   sampling interval in whole seconds (default 1)
#   -o FILE       CSV output path (default ./soak_<timestamp>.csv); the launched app's
#                 stdout/stderr go to FILE with .csv replaced by .app.log
#   -p PID        attach to an already running process instead of launching one
#
# Samples per interval: CPU % per core and total (/proc/stat), CPU0 frequency, max SoC thermal
# zone temperature (/sys/class/thermal), MX3 temperature (/sys/memx0/temperature if present;
# file format is not verified -> the largest number in the file is recorded), process RSS.
# Prints a summary at the end.
#
# Read-only on the system: writes only the CSV and the app log. Installs nothing, changes no
# settings. Run on the board, e.g.:
#   scp soak_test.sh umpi:/tmp/ && ssh umpi 'bash /tmp/soak_test.sh -m 10 -o /tmp/soak.csv -- ./app'
set -euo pipefail

usage() {  # print the leading comment block
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

minutes=10
interval=1
out=""
attach_pid=""

if [[ $# -gt 0 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then usage; exit 0; fi
while getopts ":m:i:o:p:h" opt; do
  case "$opt" in
    m) minutes="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    o) out="$OPTARG" ;;
    p) attach_pid="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) echo "error: bad option -$OPTARG" >&2; usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -gt 0 && "$1" == "--" ]]; then shift; fi

[[ "$minutes" =~ ^[0-9]+$ && "$minutes" -gt 0 ]] || { echo "error: -m must be a positive integer" >&2; exit 2; }
[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || { echo "error: -i must be a positive integer" >&2; exit 2; }
if [[ -z "$attach_pid" && $# -eq 0 ]]; then
  echo "error: give an app command after -- or attach with -p PID" >&2; usage >&2; exit 2
fi
[[ -n "$out" ]] || out="./soak_$(date +%Y%m%d_%H%M%S).csv"
applog="${out%.csv}.app.log"

# ---------------------------------------------------------------- start or attach
launched=0
if [[ -n "$attach_pid" ]]; then
  pid="$attach_pid"
  kill -0 "$pid" 2>/dev/null || { echo "error: no process $pid" >&2; exit 1; }
else
  "$@" >"$applog" 2>&1 &
  pid=$!
  launched=1
  echo "launched pid $pid: $* (log: $applog)"
fi

stop_app() {
  if [[ "$launched" -eq 1 ]] && kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "app did not exit after SIGINT, sending SIGTERM" >&2
      kill -TERM "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
}
trap 'stop_app' EXIT
trap 'echo "interrupted"; exit 130' INT TERM

# ---------------------------------------------------------------- samplers
declare -a TOT=() IDL=()
ncpu=0
read_cpu() {   # fills TOT[n], IDL[n] for each cpuN line
  local name user nice sys idle iow irq sirq steal rest n
  ncpu=0
  while read -r name user nice sys idle iow irq sirq steal rest; do
    case "$name" in
      cpu[0-9]*)
        n=${name#cpu}
        TOT[n]=$((user + nice + sys + idle + iow + irq + sirq + steal))
        IDL[n]=$((idle + iow))
        ncpu=$((n + 1))
        ;;
    esac
  done < /proc/stat
}

fmt10() {  # integer tenths -> "x.y"
  local v=$1
  printf '%d.%d' $((v / 10)) $((v % 10))
}

soc_temp() {   # max thermal zone temperature in degC (one decimal), or NA
  local best=-1 z v
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$z" ]] || continue
    v=$(cat "$z" 2>/dev/null || echo "")
    [[ "$v" =~ ^-?[0-9]+$ ]] || continue
    (( v > best )) && best=$v
  done
  if (( best < 0 )); then echo "NA"; else fmt10 $((best / 100)); fi
}

mx3_temp() {   # largest number found in /sys/memx0/temperature, or NA (format: verify on TX8)
  local f=/sys/memx0/temperature v
  if [[ -r "$f" ]]; then
    v=$(grep -oE '[0-9]+(\.[0-9]+)?' "$f" 2>/dev/null | sort -n | tail -n 1 || true)
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "NA"
}

cpu_freq() {
  local f=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
  if [[ -r "$f" ]]; then cat "$f"; else echo "NA"; fi
}

rss_kb() {
  local v
  v=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
  echo "${v:-NA}"
}

# ---------------------------------------------------------------- main loop
read_cpu
declare -a PT=() PI=()
for ((c = 0; c < ncpu; c++)); do PT[c]=${TOT[c]}; PI[c]=${IDL[c]}; done

header="t_s"
for ((c = 0; c < ncpu; c++)); do header+=",cpu${c}_pct"; done
header+=",cpu_avg_pct,cpu0_freq_khz,soc_temp_c,mx3_temp_c,rss_kb"
echo "$header" >"$out"

samples=$((minutes * 60 / interval))
t0=$(date +%s)
app_died=0
echo "sampling every ${interval}s for ${minutes} min -> $out"

for ((s = 1; s <= samples; s++)); do
  sleep "$interval"
  if ! kill -0 "$pid" 2>/dev/null; then app_died=1; echo "app (pid $pid) exited early" >&2; break; fi
  read_cpu
  line="$(( $(date +%s) - t0 ))"
  sum=0
  for ((c = 0; c < ncpu; c++)); do
    dt=$(( TOT[c] - PT[c] )); di=$(( IDL[c] - PI[c] ))
    p=0
    (( dt > 0 )) && p=$(( (1000 * (dt - di)) / dt ))
    line+=",$(fmt10 "$p")"
    sum=$((sum + p))
    PT[c]=${TOT[c]}; PI[c]=${IDL[c]}
  done
  line+=",$(fmt10 $((sum / (ncpu > 0 ? ncpu : 1))))"
  line+=",$(cpu_freq),$(soc_temp),$(mx3_temp),$(rss_kb)"
  echo "$line" >>"$out"
done

# ---------------------------------------------------------------- summary
echo
echo "=== soak summary ($out) ==="
awk -F, -v ncpu="$ncpu" '
  NR == 1 { nf = NF; for (i = 1; i <= NF; i++) name[i] = $i; next }
  {
    n++
    for (i = 2; i <= NF; i++) {
      if ($i == "NA") continue
      v = $i + 0; cnt[i]++; sum[i] += v
      if (!(i in mx) || v > mx[i]) mx[i] = v
      if (!(i in mn) || v < mn[i]) mn[i] = v
    }
    if ($NF != "NA") { if (first_rss == "") first_rss = $NF; last_rss = $NF }
    last_t = $1
  }
  END {
    printf "samples: %d, duration: %s s\n", n, last_t
    for (i = 2; i <= nf; i++) {
      if (cnt[i] == 0) { printf "%-16s n/a\n", name[i]; continue }
      printf "%-16s avg %8.1f  min %8.1f  max %8.1f\n", name[i], sum[i] / cnt[i], mn[i], mx[i]
    }
    if (first_rss != "") printf "rss growth: %d kB (first %s, last %s)\n", last_rss - first_rss, first_rss, last_rss
  }' "$out"

if [[ "$app_died" -eq 1 ]]; then
  echo "RESULT: FAIL - app exited before the end of the soak period"
  exit 1
fi
echo "RESULT: completed (check latency/fps from the app log and viewer stats)"
