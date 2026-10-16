#!/usr/bin/env bash
# perf_a53.sh - Cortex-A53 PMU summary for the TX8 (run ON THE BOARD).
#
# Usage:
#   perf_a53.sh [-d seconds] [-k] -p <pid>          attach to a running process for N seconds
#   perf_a53.sh [-k] -- <cmd> [args...]             run a command once per event group (3 runs)
#   perf_a53.sh -h | --help
#
# Options:
#   -d N   duration in seconds when attaching with -p (default 10)
#   -p PID process id to attach to
#   -k     keep the raw perf CSV files (path is printed)
#
# What it does (read-only; changes no system setting, installs nothing):
#   Runs `perf stat` in three event groups of <= 6 events each so the A53's 6 programmable
#   counters are not multiplexed:
#     group 1: cycles(0x11) instructions(0x08) L1D_REFILL(0x03) L2D_REFILL(0x17) BR_MIS_PRED(0x10) L1D_CACHE(0x04)
#     group 2: cycles + stall events 0xE0..0xE4
#     group 3: cycles + stall events 0xE5..0xE8 + STALL_SB_FULL(0xC7)
#   and prints IPC, MPKI and a stall breakdown (% of cycles; stall events overlap, they do not
#   sum to 100 %). In command mode the command is run once per group, so it must be repeatable
#   (e.g. a benchmark or a replay of recorded frames).
#
# Requirements: `perf` in PATH and kernel.perf_event_paranoid <= 2 (or run with sudo).
# Example from the dev machine:
#   scp perf_a53.sh umpi:/tmp/ && ssh umpi 'bash /tmp/perf_a53.sh -- ./bench'
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

DUR=10
PID=""
KEEP=0
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -d) [ $# -ge 2 ] || { echo "error: -d needs a value" >&2; exit 2; }; DUR="$2"; shift 2 ;;
    -p) [ $# -ge 2 ] || { echo "error: -p needs a pid" >&2; exit 2; }; PID="$2"; shift 2 ;;
    -k) KEEP=1; shift ;;
    --) shift; CMD=("$@"); break ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$PID" ] && [ ${#CMD[@]} -gt 0 ]; then
  echo "error: use either -p PID or -- cmd, not both" >&2; exit 2
fi
if [ -z "$PID" ] && [ ${#CMD[@]} -eq 0 ]; then
  echo "error: nothing to measure (give -p PID or -- cmd args)" >&2; usage >&2; exit 2
fi
case "$DUR" in ''|*[!0-9]*) echo "error: -d must be a positive integer" >&2; exit 2 ;; esac
if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
  echo "error: process $PID not found (or not accessible)" >&2; exit 2
fi

# ---- pre-flight checks (read-only) ------------------------------------------------------
if ! command -v perf >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: perf not found.
Installing it is a system change: ask the user first. Options (see references/profiling.md):
  sudo apt install linux-tools-$(uname -r) linux-tools-common   # only for Ubuntu-built kernels
  or build tools/perf from the BSP kernel source.
EOF
  exit 3
fi

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "unknown")
if [ "$(id -u)" -ne 0 ] && [ "$PARANOID" != "unknown" ] && [ "$PARANOID" -gt 2 ]; then
  cat >&2 <<EOF
error: kernel.perf_event_paranoid=$PARANOID (needs <= 2 for user-space profiling).
Either run this script with sudo, or ask the user to approve a temporary change:
  sudo sysctl kernel.perf_event_paranoid=2
This script does not change it.
EOF
  exit 3
fi

GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
CUR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "n/a")
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "n/a")
echo "# perf_a53: kernel=$(uname -r) paranoid=$PARANOID governor=$GOV cur_freq_khz=$CUR thermal_zone0=$TEMP"

TMP=$(mktemp -d /tmp/perf_a53.XXXXXX)
cleanup() { if [ "$KEEP" -eq 0 ]; then rm -rf "$TMP"; else echo "# raw CSV kept in $TMP"; fi; }
trap cleanup EXIT

G1="r11,r08,r03,r17,r10,r04"
G2="r11,re0,re1,re2,re3,re4"
G3="r11,re5,re6,re7,re8,rc7"

run_group() {
  local events="$1" out="$2"
  if [ -n "$PID" ]; then
    perf stat -x, -o "$out" -e "{$events}" -p "$PID" -- sleep "$DUR" || {
      echo "warning: perf stat failed for group {$events}" >&2; return 0; }
  else
    perf stat -x, -o "$out" -e "{$events}" -- "${CMD[@]}" || {
      echo "warning: command or perf exited non-zero for group {$events}" >&2; return 0; }
  fi
}

echo "# running group 1/3 ..."; run_group "$G1" "$TMP/g1.csv"
echo "# running group 2/3 ..."; run_group "$G2" "$TMP/g2.csv"
echo "# running group 3/3 ..."; run_group "$G3" "$TMP/g3.csv"

# get <event> <file>: prints the counter value, or NA (handles ':u' suffixes and <not counted>)
get() {
  [ -f "$2" ] || { echo NA; return; }
  awk -F, -v ev="$1" '
    /^#/ || NF < 3 { next }
    ($3 == ev || index($3, ev ":") == 1) {
      v = $1
      if (v ~ /^[0-9.]+$/) { print v } else { print "NA" }
      found = 1; exit
    }
    END { if (!found) print "NA" }' "$2"
}

# ratio helpers via awk; print NA when inputs are missing or zero
ratio() { awk -v a="$1" -v b="$2" -v m="$3" 'BEGIN{ if (a=="NA"||b=="NA"||b+0==0) print "NA"; else printf "%.3f", m*a/b }'; }

C1=$(get r11 "$TMP/g1.csv"); I1=$(get r08 "$TMP/g1.csv")
L1R=$(get r03 "$TMP/g1.csv"); L2R=$(get r17 "$TMP/g1.csv")
BRM=$(get r10 "$TMP/g1.csv"); L1A=$(get r04 "$TMP/g1.csv")

echo
echo "== Group 1: throughput and misses =="
printf "%-28s %s\n" "cycles (0x11)" "$C1"
printf "%-28s %s\n" "instructions (0x08)" "$I1"
printf "%-28s %s\n" "IPC (max 2.0)" "$(ratio "$I1" "$C1" 1)"
printf "%-28s %s\n" "L1D accesses (0x04)" "$L1A"
printf "%-28s %s\n" "L1D refills (0x03)" "$L1R"
printf "%-28s %s\n" "L1D miss rate %" "$(ratio "$L1R" "$L1A" 100)"
printf "%-28s %s\n" "L1D MPKI" "$(ratio "$L1R" "$I1" 1000)"
printf "%-28s %s\n" "L2D refills (0x17)" "$L2R"
printf "%-28s %s\n" "L2D MPKI" "$(ratio "$L2R" "$I1" 1000)"
printf "%-28s %s\n" "branch mispredicts (0x10)" "$BRM"
printf "%-28s %s\n" "branch mispredict MPKI" "$(ratio "$BRM" "$I1" 1000)"

echo
echo "== Stall breakdown (% of cycles of the same run; events overlap) =="
C2=$(get r11 "$TMP/g2.csv"); C3=$(get r11 "$TMP/g3.csv")
stall_line() {  # code name file cycles
  local v; v=$(get "$1" "$3")
  printf "%-6s %-24s %16s  %8s %%\n" "0x${1#r}" "$2" "$v" "$(ratio "$v" "$4" 100)"
}
stall_line re0 OTHER_IQ_DEP_STALL     "$TMP/g2.csv" "$C2"
stall_line re1 IC_DEP_STALL           "$TMP/g2.csv" "$C2"
stall_line re2 IUTLB_DEP_STALL        "$TMP/g2.csv" "$C2"
stall_line re3 DECODE_DEP_STALL       "$TMP/g2.csv" "$C2"
stall_line re4 OTHER_INTERLOCK_STALL  "$TMP/g2.csv" "$C2"
stall_line re5 AGU_DEP_STALL          "$TMP/g3.csv" "$C3"
stall_line re6 SIMD_DEP_STALL         "$TMP/g3.csv" "$C3"
stall_line re7 LD_DEP_STALL           "$TMP/g3.csv" "$C3"
stall_line re8 ST_DEP_STALL           "$TMP/g3.csv" "$C3"
stall_line rc7 STALL_SB_FULL          "$TMP/g3.csv" "$C3"

cat <<'EOF'

Hints (see references/profiling.md section 4):
  LD_DEP high + high L1D/L2 MPKI -> memory-bound: fuse passes, tile for L2, prefetch
  LD_DEP high + low MPKI         -> load-use latency: issue loads earlier, unroll
  SIMD_DEP high                  -> dependent NEON chains: more accumulators
  STALL_SB_FULL high             -> store-bound: fewer/narrower output passes
  branch MPKI > ~5               -> make hot loops branchless
  NA values: event not supported/counted on this kernel/PMU (check dmesg | grep -i pmu)
EOF
