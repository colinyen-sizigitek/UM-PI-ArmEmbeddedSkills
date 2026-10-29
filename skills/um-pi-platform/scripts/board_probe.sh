#!/usr/bin/env bash
# board_probe.sh -- read-only fact probe for the TX8 board (UM-PI platform).
#
# Usage (from the dev host):
#   ssh umpi 'bash -s' < board_probe.sh > board-report.md
#   ssh umpi 'bash -s' -- --no-sudo < board_probe.sh
# or copy to the board and run:  bash board_probe.sh [--no-sudo] [--help]
#
# Prints a markdown report: OS, CPU (incl. revision and A53 errata relevance), memory,
# storage, PCIe link (LnkCap/LnkSta), USB, cameras, MemryX/TurboJPEG packages, toolchain,
# cpufreq governor and thermal zones.
#
# Read-only: changes nothing. Uses `sudo -n` (never prompts) for lspci -vv; pass --no-sudo
# to skip sudo entirely. Missing tools are reported as "not found".
set -euo pipefail

USE_SUDO=1
for arg in "$@"; do
  case "$arg" in
    --no-sudo) USE_SUDO=0 ;;
    -h|--help) sed -n '2,15p' "$0" 2>/dev/null || echo "usage: board_probe.sh [--no-sudo]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n## %s\n\n' "$1"; }

# run "<title>" cmd args... : prints the command and its output in a code block, never fails.
run() {
  local title="$1"; shift
  printf '### %s\n\n```\n$ %s\n' "$title" "$*"
  if have "$1"; then
    "$@" 2>&1 || printf '(exit code %s)\n' "$?"
  else
    printf '%s: not found\n' "$1"
  fi
  printf '```\n\n'
}

# runsh "<title>" "<shell snippet>" : for pipelines; never fails.
runsh() {
  local title="$1" snippet="$2"
  printf '### %s\n\n```\n$ %s\n' "$title" "$snippet"
  bash -c "$snippet" 2>&1 || printf '(exit code %s)\n' "$?"
  printf '```\n\n'
}

catf() {
  local f
  for f in "$@"; do
    if [ -r "$f" ]; then
      printf '%s: %s\n' "$f" "$(tr '\0' ' ' < "$f" 2>/dev/null | head -c 2000)"
    else
      printf '%s: not found\n' "$f"
    fi
  done
}

printf '# TX8 board probe report\n\n'
printf -- '- Date: %s\n' "$(date -Is 2>/dev/null || date)"
printf -- '- Hostname: %s\n' "$(hostname 2>/dev/null || echo unknown)"
printf -- '- Probe: read-only, sudo=%s\n' "$([ "$USE_SUDO" = 1 ] && echo 'sudo -n (non-interactive)' || echo off)"

section "OS and kernel"
run "uname" uname -a
runsh "os-release" "grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release"
printf '### Device tree\n\n```\n'
catf /proc/device-tree/model /proc/device-tree/compatible
printf '```\n\n'
run "uptime" uptime

section "CPU"
run "lscpu" lscpu
run "nproc" nproc
runsh "Features (expect asimd crc32; no atomics/asimddp/fphp/sve)" "grep -m1 -i '^Features' /proc/cpuinfo"
runsh "MIDR fields" "grep -E '^CPU (implementer|architecture|variant|part|revision)' /proc/cpuinfo | sort | uniq -c"

# Errata relevance: Cortex-A53 = implementer 0x41, part 0xd03.
part="$(grep -m1 -E '^CPU part' /proc/cpuinfo 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}' || true)"
var="$(grep -m1 -E '^CPU variant' /proc/cpuinfo 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}' || true)"
rev="$(grep -m1 -E '^CPU revision' /proc/cpuinfo 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}' || true)"
printf '### Cortex-A53 errata relevance\n\n'
if [ "$part" = "0xd03" ]; then
  vnum=$(( ${var:-0} ))
  printf -- '- Core: Cortex-A53 r%sp%s\n' "$vnum" "${rev:-?}"
  printf -- '- Erratum 835769 (-mfix-cortex-a53-835769) and 843419 (-mfix-cortex-a53-843419):\n'
  printf -- '  Linux Kconfig lists Cortex-A53 parts up to r0p4 as affected; confirm against the Arm SDEN.\n'
  if [ "$vnum" = "0" ] && [ -n "$rev" ] && [ "$rev" -le 4 ] 2>/dev/null; then
    printf -- '- Result: revision is within r0p0..r0p4 -> enable both flags (TX8_A53_ERRATA=ON) unless the SDEN says otherwise.\n'
  else
    printf -- '- Result: revision outside r0p0..r0p4 or unknown -> check the SDEN; enable the flags if unsure.\n'
  fi
else
  printf -- '- CPU part "%s" is not 0xd03 (Cortex-A53) or unreadable -> verify manually.\n' "${part:-unknown}"
fi
printf '\n'
if have gcc; then
  runsh "GCC default fix-cortex-a53 settings" "gcc -Q --help=target 2>/dev/null | grep -i fix-cortex; gcc -v 2>&1 | tr ' ' '\n' | grep -i fix-cortex || true"
fi

section "Memory"
run "free -h" free -h
runsh "MemTotal" "grep -E '^(MemTotal|MemAvailable|SwapTotal)' /proc/meminfo"
printf -- '- Note: EVT boards 2 GB, MP boards 4 GB; size buffers at runtime.\n\n'

section "Caches"
runsh "cache topology" "for d in /sys/devices/system/cpu/cpu0/cache/index*; do [ -d \"\$d\" ] && echo \"\$(basename \$d): L\$(cat \$d/level) \$(cat \$d/type) \$(cat \$d/size) line=\$(cat \$d/coherency_line_size 2>/dev/null)\"; done"

section "Storage"
run "lsblk" lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
run "df" df -h /

section "PCIe"
run "lspci -nn" lspci -nn
printf '### lspci -vv link capability / status\n\n```\n'
if have lspci; then
  if [ "$USE_SUDO" = 1 ] && have sudo && sudo -n true 2>/dev/null; then
    sudo -n lspci -vv 2>&1 | grep -E '^[0-9a-f]{2,4}:|LnkCap:|LnkSta:' || echo "(no link lines)"
  else
    echo "(sudo not available without password -- run manually: ssh -t umpi 'sudo lspci -vv | grep -E \"LnkCap|LnkSta\"')"
    lspci -vv 2>&1 | grep -E '^[0-9a-f]{2,4}:|LnkCap:|LnkSta:' || echo "(no link lines visible without root)"
  fi
else
  echo "lspci: not found (package pciutils)"
fi
printf '```\n\n'
printf -- '- Note: MemryX datasheet says Gen3 x2, slot is x4. Report LnkSta Speed/Width.\n\n'
runsh "PCIe AER / link errors in dmesg" "dmesg 2>/dev/null | grep -iE 'pcieport|aer|memx|link down|receiver error' | tail -20 || echo 'dmesg not readable or no PCIe errors'"

section "USB"
run "lsusb" lsusb
run "lsusb -t" lsusb -t
runsh "USB autosuspend setting (can stall UVC cameras if >0)" "cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null || echo 'not exposed'"

section "Cameras (V4L2)"
run "v4l2-ctl --list-devices" v4l2-ctl --list-devices
if have v4l2-ctl; then
  for dev in /dev/video*; do
    [ -e "$dev" ] || continue
    run "formats $dev" v4l2-ctl -d "$dev" --list-formats-ext
  done
fi
runsh "stable paths" "ls -l /dev/v4l/by-id/ /dev/v4l/by-path/ 2>/dev/null || echo 'no /dev/v4l links'"

section "MemryX"
runsh "packages (memx / turbojpeg / libjpeg)" "dpkg -l 2>/dev/null | grep -E 'memx|turbojpeg|libjpeg' || echo 'none found'"
runsh "apt policy memx-drivers" "apt policy memx-drivers 2>/dev/null | head -5 || echo 'apt: not available'"
printf '### /sys/memx0\n\n```\n'
catf /sys/memx0/verinfo /sys/memx0/temperature
printf '```\n\n'
runsh "device nodes" "ls -l /dev/memx* 2>/dev/null || echo 'no /dev/memx*'"
runsh "memx-accl files (cmake/pkg-config/libs)" "dpkg -L memx-accl 2>/dev/null | grep -E 'cmake|\\.pc\$|\\.so' | head -40 || echo 'memx-accl not installed'"
runsh "mxa-manager service" "systemctl list-unit-files 2>/dev/null | grep -i mxa || echo 'no mxa unit'; systemctl is-active mxa-manager 2>/dev/null || true"
printf '### /etc/memryx/mxa_manager.conf\n\n```\n'
if [ -r /etc/memryx/mxa_manager.conf ]; then cat /etc/memryx/mxa_manager.conf; else echo "not found"; fi
printf '```\n\n'

section "Toolchain"
run "gcc" gcc --version
run "g++" g++ --version
runsh "glibc" "ldd --version 2>&1 | head -1"
run "cmake" cmake --version
runsh "pkg-config libturbojpeg" "pkg-config --modversion libturbojpeg 2>/dev/null || echo 'libturbojpeg.pc not found (libturbojpeg0-dev?)'"

section "CPU frequency"
runsh "governors" "for c in /sys/devices/system/cpu/cpu[0-9]*; do f=\$c/cpufreq; [ -d \$f ] && echo \"\$(basename \$c): gov=\$(cat \$f/scaling_governor 2>/dev/null) min=\$(cat \$f/scaling_min_freq 2>/dev/null) max=\$(cat \$f/scaling_max_freq 2>/dev/null) cur=\$(cat \$f/scaling_cur_freq 2>/dev/null)\"; done; true"
runsh "available frequencies" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo 'not exposed'"

section "Thermal"
runsh "thermal zones (millidegree C)" "for z in /sys/class/thermal/thermal_zone*; do [ -d \$z ] && echo \"\$(basename \$z) type=\$(cat \$z/type 2>/dev/null) temp=\$(cat \$z/temp 2>/dev/null) trips=\$(cat \$z/trip_point_*_temp 2>/dev/null | tr '\n' ' ')\"; done; true"

section "Profiling access"
runsh "perf_event_paranoid" "cat /proc/sys/kernel/perf_event_paranoid"
runsh "PMU in dmesg" "dmesg 2>/dev/null | grep -i pmu | head -5 || echo 'dmesg not readable (needs root) or no PMU lines'"
run "perf" perf --version

section "Network"
runsh "interfaces" "ip -br addr 2>/dev/null || ifconfig -a"

printf '\n---\nEnd of report. Facts not shown here are "verify on TX8".\n'
