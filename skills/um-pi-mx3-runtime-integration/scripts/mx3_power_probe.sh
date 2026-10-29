#!/usr/bin/env bash
# mx3_power_probe.sh - sample MX3 temperature, SoC temperature and any board power sensors over
# time for one measurement phase (run ON the TX8 board). Read-only unless --run-cmd is given.
#
# Usage:
#   bash mx3_power_probe.sh --phase NAME [--seconds N] [--interval S] [--out FILE] [--run-cmd CMD --yes]
#
#   --phase NAME     label, e.g. idle | running | after_release | after_release_60s (required)
#   --seconds N      duration (default 60)
#   --interval S     sampling interval in seconds (default 1)
#   --out FILE       CSV output (appends; header written when the file is new). Default: stdout
#   --run-cmd CMD    start CMD in the background for this phase (e.g. the application, or
#                    'acclBench -d m_c4.dfp -f 100000 -b --set_freq 300 --power'); it is stopped
#                    with SIGTERM at the end of the phase. Requires --yes because it activates the
#                    MX3 (and --set_freq changes its clock).
#   --yes            confirm --run-cmd
#   -h, --help       this help
#
# Columns: utc,phase,elapsed_s,mx3_temp_max_c,mx3_temp_raw,soc_temp_max_c,hwmon_power_mw,hwmon_detail,memx_dev
#   hwmon_power_mw = sum of all /sys/class/hwmon/*/power*_input (uW -> mW); empty if the board exposes none.
#   MX3 module power is NOT visible from sysfs here: read it in the application with
#   get_power() (mW) or from 'acclBench --power' output while running. Use an external meter for
#   whole-board power. Typical sequence: idle (never started since boot) -> running -> after_release.
# Exit: 0 ok, 2 usage error, 3 --run-cmd without --yes.
set -euo pipefail

PHASE=""; SECS=60; INTERVAL=1; OUT=""; RUNCMD=""; YES=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:?}"; shift 2 ;;
    --seconds) SECS="${2:?}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --run-cmd) RUNCMD="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$PHASE" ]] || { usage >&2; die "--phase is required"; }
[[ "$PHASE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--phase: letters, digits, _ . - only"
[[ "$SECS" =~ ^[0-9]+$ && "$SECS" -ge 1 ]] || die "--seconds must be a positive integer"
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || die "--interval must be a positive integer"

if [[ -n "$RUNCMD" && $YES -eq 0 ]]; then
  echo "WARNING: --run-cmd will start: $RUNCMD" >&2
  echo "         This activates the MX3 (and may change its clock). Re-run with --yes to proceed." >&2
  exit 3
fi
if [[ -n "$RUNCMD" ]] && grep -qE -- '--set_freq[ =]+([0-9]+)' <<< "$RUNCMD"; then
  f="$(grep -oE -- '--set_freq[ =]+[0-9]+' <<< "$RUNCMD" | grep -oE '[0-9]+$' | head -n 1)"
  if (( f > 400 )); then die "--run-cmd sets ${f} MHz: above the 400 MHz product rule; refused"; fi
fi

HEADER="utc,phase,elapsed_s,mx3_temp_max_c,mx3_temp_raw,soc_temp_max_c,hwmon_power_mw,hwmon_detail,memx_dev"
emit() { if [[ -n "$OUT" ]]; then echo "$1" >> "$OUT"; else echo "$1"; fi; }
if [[ -n "$OUT" && ! -s "$OUT" ]]; then echo "$HEADER" > "$OUT"; elif [[ -z "$OUT" ]]; then echo "$HEADER"; fi

mx3_temp() {
  if [[ -r /sys/memx0/temperature ]]; then
    local raw
    raw="$(tr '\n' ' ' 2>/dev/null < /sys/memx0/temperature || true)"
    local mx
    mx="$(grep -oE '[0-9]+(\.[0-9]+)?' <<< "$raw" | awk 'BEGIN{m=""} {if(m==""||$1+0>m+0)m=$1} END{print m}' || true)"
    printf '%s,"%s"' "$mx" "${raw//\"/}"
  else
    printf ',"n/a"'
  fi
}
soc_temp() {
  local m=""
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$z" ]] || continue
    local v; v="$(cat "$z" 2>/dev/null || true)"
    [[ "$v" =~ ^-?[0-9]+$ ]] || continue
    if [[ -z "$m" ]] || (( v > m )); then m="$v"; fi
  done
  if [[ -n "$m" ]]; then awk -v v="$m" 'BEGIN{printf "%.1f", v/1000}'; fi
}
hwmon_power() {   # prints "<sum_mw>,<detail>"
  local sum=0 n=0 detail=""
  for p in /sys/class/hwmon/hwmon*/power*_input; do
    [[ -r "$p" ]] || continue
    local uw; uw="$(cat "$p" 2>/dev/null || true)"
    [[ "$uw" =~ ^[0-9]+$ ]] || continue
    local name; name="$(cat "$(dirname "$p")/name" 2>/dev/null || echo hwmon)"
    sum=$(( sum + uw )); n=$(( n + 1 ))
    detail+="${detail:+ }${name}:$(basename "$p" _input)=$(( uw / 1000 ))mW"
  done
  if (( n > 0 )); then printf '%d,"%s"' $(( sum / 1000 )) "$detail"; else printf ',""'; fi
}

RPID=""
cleanup() {
  if [[ -n "$RPID" ]] && kill -0 "$RPID" 2>/dev/null; then
    kill -TERM -- "-$RPID" 2>/dev/null || kill -TERM "$RPID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$RPID" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$RPID" 2>/dev/null || kill -KILL "$RPID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -n "$RUNCMD" ]]; then
  echo "phase $PHASE: starting workload: $RUNCMD" >&2
  # own process group (setsid) so the whole workload tree can be stopped at the end
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$RUNCMD" > "./power_probe_${PHASE}_workload.log" 2>&1 &
  else
    bash -c "$RUNCMD" > "./power_probe_${PHASE}_workload.log" 2>&1 &
  fi
  RPID=$!
fi

start=$SECONDS
while (( SECONDS - start < SECS )); do
  dev="no"; [[ -e /dev/memx0 ]] && dev="yes"
  emit "$(date -u +%Y-%m-%dT%H:%M:%SZ),$PHASE,$(( SECONDS - start )),$(mx3_temp),$(soc_temp),$(hwmon_power),$dev"
  if [[ -n "$RPID" ]] && ! kill -0 "$RPID" 2>/dev/null; then
    echo "phase $PHASE: workload exited early (see ./power_probe_${PHASE}_workload.log)" >&2
    RPID=""
  fi
  sleep "$INTERVAL"
done
echo "phase $PHASE: done (${SECS}s). Record external meter readings for the same window." >&2
exit 0
