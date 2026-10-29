#!/usr/bin/env bash
# mx3_diag.sh - read-only MemryX MX3 / TX8 diagnostics report (run ON the board).
#
# Usage:
#   bash mx3_diag.sh [--no-sudo] [-h|--help]
#   ssh umpi 'bash -s' < mx3_diag.sh > diag.txt          # from the dev machine
#
#   --no-sudo   never try `sudo -n` (default: try sudo non-interactively for lspci -vv only)
#
# Collects: OS/kernel/CPU/RAM, memx packages (apt policy, dpkg), runtime headers and CMake/pkg-config
# files, /dev/memx*, /sys/memx0 (verinfo, temperature), kernel module + dmesg, PCIe link speed/width
# (sysfs + lspci), mxa-manager status/config, /etc/memryx files, tool versions (acclBench/mx_bench
# --hello), SoC thermal zones and hwmon sensors.
# Changes nothing: no installs, no config edits, no clock changes, no service restarts.
# Exit code is always 0 unless the arguments are wrong (2); read the report for problems.
set -euo pipefail

USE_SUDO=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-sudo) USE_SUDO=0; shift ;;
    -h|--help) sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

sec() { printf '\n==================== %s ====================\n' "$1"; }
run() {   # run a shell snippet, never fail the script
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1 || printf '(exit %s)\n' "$?"
}
have() { command -v "$1" >/dev/null 2>&1; }

echo "MX3 diagnostics report - $(date -u +%Y-%m-%dT%H:%M:%SZ) - host $(hostname)"

sec "System"
run 'uname -a'
run 'grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release'
run 'nproc; grep -E "CPU (implementer|part|variant|revision)" /proc/cpuinfo | sort | uniq -c'
run 'free -m'
run 'uptime'

sec "MemryX packages"
run 'apt policy memx-drivers memx-accl 2>/dev/null'
run 'dpkg -l 2>/dev/null | grep -i -E "memx|memryx"'
run 'dpkg -L memx-accl 2>/dev/null | grep -E "\.h$|\.so|[Cc]onfig\.cmake|\.pc$|/bin/" | head -80'
run 'ls -l /usr/include/memx/accl/ 2>/dev/null'
run 'grep -n -E "set_operating_frequency|connect_dfp|MxAcclMT\(|send_input|receive_output" /usr/include/memx/accl/MxAcclBase.h /usr/include/memx/accl/MxAcclMT.h /usr/include/memx/accl/MxAccl.h 2>/dev/null | head -40'
run 'grep -n -E "FREQ_USE_CONF|FREQ_300MHz|FREQ_400MHz" /usr/include/memx/accl/utils/mxTypes.h 2>/dev/null | head'
run 'python3 -m pip show memryx 2>/dev/null | head -3'

sec "Device nodes and driver"
run 'ls -l /dev/memx* 2>/dev/null'
run 'ls -l /sys/memx0/ 2>/dev/null'
run 'cat /sys/memx0/verinfo 2>/dev/null'
run 'lsmod | grep -i memx'
run 'dmesg 2>/dev/null | grep -i memx | tail -40 || echo "(dmesg not readable without root)"'

sec "MX3 temperature (5 samples, 1 s)"
for _ in 1 2 3 4 5; do
  printf '%s  ' "$(date +%T)"; tr '\n' ' ' 2>/dev/null < /sys/memx0/temperature || printf 'n/a'; echo
  sleep 1
done
echo "Note: <100 C normal; >100 C throttling; 255 C = chip lock-up, reboot required."

sec "PCIe link"
bdfs="$(lspci -D 2>/dev/null | grep -i -E 'memryx|processing accelerator' | awk '{print $1}' || true)"
if [[ -z "$bdfs" ]]; then
  echo "MemryX device not identified by name/class in lspci. Full list:"
  run 'lspci -nn 2>/dev/null'
else
  for b in $bdfs; do
    echo "device $b: $(lspci -s "$b" -nn 2>/dev/null || true)"
    for a in current_link_speed current_link_width max_link_speed max_link_width; do
      printf '  %-20s %s\n' "$a" "$(cat "/sys/bus/pci/devices/$b/$a" 2>/dev/null || echo n/a)"
    done
    if (( USE_SUDO )) && sudo -n true 2>/dev/null; then
      sudo -n lspci -vv -s "$b" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|LnkCtl2:' || true
    else
      echo "  (lspci -vv LnkCap/LnkSta need root: run 'sudo lspci -vv -s $b | grep Lnk' manually)"
    fi
  done
  echo "Expected: 8.0 GT/s (Gen3), width x2 (module spec) on the x4 slot. Lower = report HW issue."
fi

sec "mxa-manager (shared mode service)"
run 'systemctl is-active mxa-manager; systemctl status mxa-manager --no-pager 2>/dev/null | head -15'
run 'cat /etc/memryx/mxa_manager.conf 2>/dev/null'
run 'ls -l /run/mxa_manager/ 2>/dev/null'
run 'journalctl -u mxa-manager --no-pager -n 30 2>/dev/null'

sec "/etc/memryx (power mode config, read only)"
run 'ls -l /etc/memryx/ 2>/dev/null'
run 'cat /etc/memryx/power.conf 2>/dev/null'

sec "Tools"
for t in acclBench mx_bench mx_set_powermode dfp_inspect; do
  if have "$t"; then echo "$t: $(command -v "$t")"; else echo "$t: not found"; fi
done
if have acclBench; then
  run 'acclBench --help 2>&1 | grep -E "set_freq|power|shared|device_ids|frames" | head -12'
  run 'timeout 20 acclBench --hello'
elif have mx_bench; then
  run 'timeout 30 mx_bench --hello'
fi

sec "SoC thermal zones"
for z in /sys/class/thermal/thermal_zone*; do
  [[ -d "$z" ]] || continue
  printf '%-40s %-20s %s\n' "$z" "$(cat "$z/type" 2>/dev/null || echo ?)" "$(cat "$z/temp" 2>/dev/null || echo ?)"
done

sec "hwmon sensors (board power if available)"
for h in /sys/class/hwmon/hwmon*; do
  [[ -d "$h" ]] || continue
  echo "$h name=$(cat "$h/name" 2>/dev/null || echo ?)"
  for f in "$h"/power*_input "$h"/curr*_input "$h"/in*_input "$h"/temp*_input; do
    if [[ -r "$f" ]]; then printf '  %-28s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || echo ?)"; fi
  done
done
echo "Units (kernel hwmon ABI): power uW, current mA, voltage mV, temp m-degC."

sec "End"
echo "Report complete. Nothing was changed on the system."
exit 0
