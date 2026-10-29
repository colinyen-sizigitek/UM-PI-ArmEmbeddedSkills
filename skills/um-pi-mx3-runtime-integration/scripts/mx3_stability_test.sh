#!/usr/bin/env bash
# mx3_stability_test.sh - on-board MX3 stability test for one DFP at one or more clocks (run ON TX8).
# Produces CSV rows in the tx8-freq-matrix.csv format so results can be appended to the matrix:
#   model,freq_mhz,status,fps,cpu,power_mw,voltage_mv,temp_c,mpu_config,note
#
# Usage:
#   bash mx3_stability_test.sh --dfp FILE --model NAME [options]
#
# Required:
#   --dfp FILE            DFP to test (compiled for --chips chips)
#   --model NAME          model name for the CSV (use the matrix naming, e.g. YOLO26_nano_640_640_3_onnx)
# Options:
#   --chips N             chip count the DFP was compiled for (default 4) -> mpu_config "Nx1"
#   --freqs "LIST"        MHz list, multiples of 25 (default "300 400"); values > 400 need --allow-above-400
#   --minutes M           minutes per clock (default 10, product target is >= 10)
#   --interval S          temperature sampling interval in seconds (default 5)
#   --tool T              acclBench | mx_bench | auto (default auto: acclBench if it supports --set_freq)
#   --frames N            frames per long run (default: calibrated from a 300-frame run x minutes)
#   --shared              run acclBench in shared mode (-s, via mxa-manager); default local mode
#   --cooldown S          seconds to wait between clocks (default 60)
#   --out FILE            CSV to append rows to (header written if the file is new); default stdout only
#   --logdir DIR          raw logs (default ./mx3_stability_<timestamp>)
#   --yes                 REQUIRED to actually run: the test changes the MX3 clock (acclBench --set_freq)
#   --allow-above-400     permit clocks above 400 MHz (VIOLATES the product rule; analysis only)
#   --assume-freq-set     with --tool mx_bench: you already set the clock with `sudo mx_set_powermode`
#                         to the single value in --freqs (mx_bench has no clock option)
#   -h, --help            this help
#
# PASS criteria per clock: benchmark exit 0, no timeout/hang, fps > 0, max chip temperature < 100 C,
# no 255 C reading. A 255 C reading aborts everything: the chip is locked and the board must be
# rebooted. The note column records date, minutes, tool, max temp, calibration fps and rc.
# cpu column = average host CPU utilisation in % over the run (all cores) - note the unit differs
# from the MemryX table (unspecified unit). voltage_mv is left empty (not observable from user space).
# Exit: 0 all clocks PASS, 1 at least one NG, 2 usage/environment error, 3 not confirmed (--yes missing),
#       4 chip lock-up (255 C) detected.
set -euo pipefail

DFP=""; MODEL=""; CHIPS=4; FREQS="300 400"; MINUTES=10; INTERVAL=5; TOOL="auto"; FRAMES=""
SHARED=0; COOLDOWN=60; OUT=""; LOGDIR=""; YES=0; ALLOW_ABOVE=0; ASSUME_SET=0

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dfp) DFP="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --chips) CHIPS="${2:?}"; shift 2 ;;
    --freqs) FREQS="${2:?}"; shift 2 ;;
    --minutes) MINUTES="${2:?}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --tool) TOOL="${2:?}"; shift 2 ;;
    --frames) FRAMES="${2:?}"; shift 2 ;;
    --shared) SHARED=1; shift ;;
    --cooldown) COOLDOWN="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --logdir) LOGDIR="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --allow-above-400) ALLOW_ABOVE=1; shift ;;
    --assume-freq-set) ASSUME_SET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DFP" && -n "$MODEL" ]] || { usage >&2; die "--dfp and --model are required"; }
[[ -f "$DFP" ]] || die "DFP not found: $DFP"
[[ "$MODEL" =~ ^[A-Za-z0-9_.+-]+$ ]] || die "--model: letters, digits, _ . + - only"
[[ "$CHIPS" =~ ^[1-4]$ ]] || die "--chips must be 1..4"
[[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 ]] || die "--minutes must be a positive integer"
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || die "--interval must be a positive integer"
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] || die "--cooldown must be an integer"
[[ -z "$FRAMES" || "$FRAMES" =~ ^[0-9]+$ ]] || die "--frames must be an integer"
[[ -n "${FREQS// /}" ]] || die "--freqs must not be empty"

ABOVE=0
for f in $FREQS; do
  [[ "$f" =~ ^[0-9]+$ ]] || die "bad frequency '$f'"
  (( f >= 200 && f <= 1000 && f % 25 == 0 )) || die "frequency $f must be 200..1000 MHz in 25 MHz steps"
  if (( f > 400 )); then ABOVE=1; fi
done
if (( ABOVE )); then
  if (( ! ALLOW_ABOVE )); then
    die "clock above 400 MHz requested ($FREQS). Product rule: MX3 clock <= 400 MHz. Use --allow-above-400 only for analysis."
  fi
  cat >&2 <<'EOF'
############################################################################
#  WARNING: CLOCK ABOVE 400 MHz REQUESTED (--allow-above-400).            #
#  This VIOLATES the TX8 product rule. Higher clocks raise power and heat #
#  and may lock up the chip (255 C), which requires a board reboot.       #
#  Results are for analysis only and must never be used for deployment.  #
############################################################################
EOF
fi

[[ -e /dev/memx0 ]] || die "/dev/memx0 not found - run mx3_diag.sh"
[[ -r /sys/memx0/temperature ]] || echo "WARNING: /sys/memx0/temperature not readable; temperature checks disabled" >&2

if [[ "$TOOL" == "auto" ]]; then
  if command -v acclBench >/dev/null 2>&1 && acclBench --help 2>&1 | grep -q -- 'set_freq'; then
    TOOL="acclBench"
  elif command -v mx_bench >/dev/null 2>&1; then
    TOOL="mx_bench"
  else
    die "neither acclBench (with --set_freq) nor mx_bench found"
  fi
fi
case "$TOOL" in
  acclBench)
    command -v acclBench >/dev/null 2>&1 || die "acclBench not found"
    acclBench --help 2>&1 | grep -q -- 'set_freq' || die "installed acclBench has no --set_freq option; use --tool mx_bench --assume-freq-set"
    ;;
  mx_bench)
    command -v mx_bench >/dev/null 2>&1 || die "mx_bench not found"
    n_f=$(wc -w <<< "$FREQS")
    (( n_f == 1 )) || die "mx_bench cannot set the clock: test one frequency per run (--freqs \"300\")"
    (( ASSUME_SET )) || die "mx_bench has no clock option: set it first with 'sudo mx_set_powermode' (needs approval), then pass --assume-freq-set"
    ;;
  *) die "--tool must be acclBench, mx_bench or auto" ;;
esac

echo "Plan: DFP=$DFP model=$MODEL chips=$CHIPS clocks=[$FREQS] MHz, ${MINUTES} min each, tool=$TOOL, mode=$( ((SHARED)) && echo shared || echo local )"
if [[ "$TOOL" == "acclBench" ]]; then
  echo "This test SETS THE MX3 CLOCK with 'acclBench --set_freq <MHz>' for each run."
fi
if (( ! YES )); then
  echo "WARNING: running this test changes the MX3 operating frequency and loads the accelerator for" >&2
  echo "         about $(( $(wc -w <<< "$FREQS") * (MINUTES + 2) )) minutes. Re-run with --yes to proceed." >&2
  exit 3
fi

TS="$(date +%Y%m%d_%H%M%S)"
[[ -n "$LOGDIR" ]] || LOGDIR="./mx3_stability_$TS"
mkdir -p "$LOGDIR"
HEADER="model,freq_mhz,status,fps,cpu,power_mw,voltage_mv,temp_c,mpu_config,note"
if [[ -n "$OUT" && ! -s "$OUT" ]]; then echo "$HEADER" > "$OUT"; fi

read_temp_max() {   # prints max number found in /sys/memx0/temperature, or empty
  [[ -r /sys/memx0/temperature ]] || return 0
  grep -oE '[0-9]+(\.[0-9]+)?' /sys/memx0/temperature 2>/dev/null \
    | awk 'BEGIN{m=""} {if (m=="" || $1+0>m+0) m=$1} END{if (m!="") print m}' || true
}
cpu_snapshot() { awk '/^cpu / {idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print tot, idle}' /proc/stat; }
strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

parse_fps() {   # $1 = log file
  local v
  v="$(strip_ansi < "$1" | awk -F: '/Average FPS for DFP/ {gsub(/[^0-9.]/, "", $2); v=$2} END{print v}')"
  if [[ -z "$v" ]]; then   # mx_bench / unknown format: last number on the last line mentioning FPS
    v="$(strip_ansi < "$1" | grep -i 'fps' | tail -n 1 | grep -oE '[0-9]+(\.[0-9]+)?' | tail -n 1 || true)"
  fi
  printf '%s' "$v"
}
parse_power_mw() {
  local w
  w="$(strip_ansi < "$1" | awk -F: '/Average Power for DFP/ {gsub(/[^0-9.]/, "", $NF); w=$NF} END{print w}')"
  if [[ -n "$w" ]]; then awk -v w="$w" 'BEGIN{printf "%d", w*1000+0.5}'; fi
}

BENCH=()
bench_cmd() {   # $1 freq, $2 frames -> fills the global array BENCH
  if [[ "$TOOL" == "acclBench" ]]; then
    BENCH=(acclBench -d "$DFP" -f "$2" -b --set_freq "$1" --power)
    if (( SHARED )); then BENCH+=(-s); fi
  else
    BENCH=(mx_bench -v -d "$DFP" -f "$2")
  fi
}

ANY_NG=0
LOCKED=0
first=1
for FREQ in $FREQS; do
  if (( ! first )) && (( COOLDOWN > 0 )); then echo "cool-down ${COOLDOWN}s ..."; sleep "$COOLDOWN"; fi
  first=0
  echo "=== ${FREQ} MHz ==="
  t_start="$(read_temp_max)"

  # 1) calibration run to size the long run
  fps_cal=""
  if [[ -z "$FRAMES" ]]; then
    cal_log="$LOGDIR/cal_${FREQ}.log"
    bench_cmd "$FREQ" 300
    echo "+ ${BENCH[*]}" > "$cal_log"
    set +e
    timeout 300 "${BENCH[@]}" >> "$cal_log" 2>&1
    rc_cal=$?
    set -e
    fps_cal="$(parse_fps "$cal_log")"
    if [[ $rc_cal -ne 0 || -z "$fps_cal" ]]; then
      echo "calibration failed (rc=$rc_cal) - see $cal_log" >&2
      row="\"$MODEL\",$FREQ,NG,,,,,${t_start},${CHIPS}x1,TX8 stability $(date +%F) calibration failed rc=$rc_cal tool=$TOOL"
      echo "$row"; [[ -n "$OUT" ]] && echo "$row" >> "$OUT"
      ANY_NG=1; continue
    fi
    frames=$(awk -v f="$fps_cal" -v m="$MINUTES" 'BEGIN{n=int(f*m*60+0.5); if(n<500)n=500; print n}')
  else
    frames="$FRAMES"
  fi

  # 2) long run with temperature sampling
  run_log="$LOGDIR/run_${FREQ}.log"
  temp_log="$LOGDIR/temp_${FREQ}.csv"
  echo "epoch_s,max_chip_temp_c,raw" > "$temp_log"
  limit=$(( MINUTES * 60 * 2 + 120 ))          # hang guard: 2x planned duration + 2 min
  read -r c0_tot c0_idle < <(cpu_snapshot)
  bench_cmd "$FREQ" "$frames"
  echo "+ ${BENCH[*]}" > "$run_log"
  # timeout forwards TERM to the benchmark; rc 124 = time limit hit, 137 = killed after grace period
  timeout --kill-after=30 "$limit" "${BENCH[@]}" >> "$run_log" 2>&1 &
  bpid=$!
  tmax=""
  THERM_ABORT=0
  while kill -0 "$bpid" 2>/dev/null; do
    t="$(read_temp_max)"
    raw="$(tr '\n' ' ' 2>/dev/null < /sys/memx0/temperature || true)"
    echo "$(date +%s),${t},\"${raw//\"/}\"" >> "$temp_log"
    if [[ -n "$t" ]]; then
      if [[ -z "$tmax" ]] || awk -v a="$t" -v b="$tmax" 'BEGIN{exit !(a>b)}'; then tmax="$t"; fi
      if awk -v a="$t" 'BEGIN{exit !(a>=254.5)}'; then
        echo "!!! 255 C reading: chip LOCK-UP. Stopping the benchmark. A board reboot is required. !!!" >&2
        kill -TERM "$bpid" 2>/dev/null || true
        LOCKED=1
        break
      fi
      if awk -v a="$t" 'BEGIN{exit !(a>=98.0)}'; then
        echo "!!! Proactive thermal cut-off: ${t} C >= 98 C. Stopping run BEFORE 255 C PCIe lock-up! !!!" >&2
        kill -TERM "$bpid" 2>/dev/null || true
        THERM_ABORT=1
        break
      fi
    fi
    sleep "$INTERVAL"
  done
  set +e
  wait "$bpid"
  rc=$?
  set -e
  read -r c1_tot c1_idle < <(cpu_snapshot)
  cpu=$(awk -v t0="$c0_tot" -v i0="$c0_idle" -v t1="$c1_tot" -v i1="$c1_idle" \
        'BEGIN{dt=t1-t0; if(dt<=0){print ""} else printf "%.1f", 100*(1-(i1-i0)/dt)}')
  fps="$(parse_fps "$run_log")"
  pmw="$(parse_power_mw "$run_log" || true)"

  status="PASS"; why=""
  if (( LOCKED )); then status="NG"; why="255C lock-up reboot required";
  elif (( THERM_ABORT )); then status="NG"; why="proactive thermal abort at ${tmax}C (>=98C)";
  elif [[ $rc -eq 124 || $rc -eq 137 ]]; then status="NG"; why="timeout/hang rc=$rc";
  elif [[ $rc -ne 0 ]]; then status="NG"; why="benchmark rc=$rc";
  elif [[ -z "$fps" ]] || ! awk -v f="$fps" 'BEGIN{exit !(f>0)}'; then status="NG"; why="no fps parsed";
  elif [[ -n "$tmax" ]] && awk -v a="$tmax" 'BEGIN{exit !(a>=100)}'; then status="NG"; why="max temp ${tmax}C >= 100C (throttling)";
  fi
  [[ "$status" == "PASS" ]] || ANY_NG=1
  freqnote=""; [[ "$TOOL" == "mx_bench" ]] && freqnote=" clock set externally (unverified)"
  note="TX8 stability $(date +%F) ${MINUTES}min tool=$TOOL frames=$frames cal_fps=${fps_cal:-n/a} tstart=${t_start:-n/a}C tmax=${tmax:-n/a}C cpu=%host rc=$rc${why:+ $why}${freqnote}"
  note="${note//,/;}"; note="${note//\"/}"
  row="\"$MODEL\",$FREQ,$status,$fps,$cpu,$pmw,,${tmax},${CHIPS}x1,\"$note\""
  echo "$row"
  if [[ -n "$OUT" ]]; then echo "$row" >> "$OUT"; fi
  if (( LOCKED )); then
    echo "Aborting remaining clocks. Logs: $LOGDIR" >&2
    exit 4
  fi
done

echo "Logs: $LOGDIR"
[[ -n "$OUT" ]] && echo "Rows appended to: $OUT (review, then append to tx8-freq-matrix.csv per frequency-rule.md)"
(( ANY_NG == 0 )) || exit 1
exit 0
