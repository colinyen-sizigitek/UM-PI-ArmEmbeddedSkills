#!/usr/bin/env bash
# check_compile_env.sh - read-only report of the MemryX compile environment (x86 WSL2/Linux).
#
# Usage:
#   bash check_compile_env.sh [--venv DIR] [--min-ram-gb N] [--min-disk-gb N] [-h|--help]
#
#   --venv DIR       activate this Python venv before checking (e.g. ~/mx); default: current env
#   --min-ram-gb N   RAM threshold for a WARN (default 8, MemryX recommendation)
#   --min-disk-gb N  free space in $HOME for a WARN (default 20)
#
# Checks: CPU arch (x86_64 expected; aarch64 = you are probably on the board -> do not compile
# there), WSL detection, OS release, AVX2, RAM, disk, nproc, python3 version (3.9-3.12), venv,
# mx_nc / dfp_inspect / mx_sim on PATH, `mx_nc --version`, pip package `memryx`, python modules
# onnx / onnxruntime. Prints PASS / WARN / FAIL lines.
# Never installs anything. Suggested fixes are printed, not executed.
# Exit: 0 = no FAIL, 1 = at least one FAIL, 2 = usage error.
set -euo pipefail

VENV=""
MIN_RAM_GB=8
MIN_DISK_GB=20

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv) VENV="${2:?--venv needs a directory}"; shift 2 ;;
    --min-ram-gb) MIN_RAM_GB="${2:?}"; shift 2 ;;
    --min-disk-gb) MIN_DISK_GB="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

FAILS=0
pass() { printf 'PASS  %-22s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-22s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-22s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

if [[ -n "$VENV" ]]; then
  if [[ -f "$VENV/bin/activate" ]]; then
    # shellcheck disable=SC1091
    set +u; . "$VENV/bin/activate"; set -u
    pass "venv" "activated $VENV"
  else
    fail "venv" "$VENV/bin/activate not found (create: python3.11 -m venv $VENV)"
  fi
fi

echo "== MemryX compile environment report ($(date -u +%Y-%m-%dT%H:%M:%SZ)) =="

arch="$(uname -m)"
case "$arch" in
  x86_64) pass "arch" "$arch" ;;
  aarch64) fail "arch" "aarch64: compile on the x86 dev machine (WSL2/Linux), not on the TX8 board" ;;
  *) fail "arch" "$arch (unsupported)" ;;
esac

if grep -qi microsoft /proc/version 2>/dev/null; then
  pass "host" "WSL2 ($(uname -r))"
else
  pass "host" "native Linux ($(uname -r))"
fi

if [[ -r /etc/os-release ]]; then
  os="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
  case "$os" in
    *"Ubuntu 22.04"*|*"Ubuntu 24.04"*|*"Ubuntu 20.04"*|*"Debian GNU/Linux 1"[1-9]*) pass "os" "$os" ;;
    *) warn "os" "$os (MemryX recommends Ubuntu >= 20.04 or Debian >= 11; team standard Ubuntu 22.04)" ;;
  esac
else
  warn "os" "/etc/os-release not readable"
fi

if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
  pass "avx2" "present"
else
  fail "avx2" "AVX2 missing - mx_nc requires AVX2"
fi

mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$(( mem_kb / 1024 / 1024 ))
if (( mem_gb >= MIN_RAM_GB )); then
  pass "ram" "${mem_gb} GB"
else
  warn "ram" "${mem_gb} GB < ${MIN_RAM_GB} GB (WSL2: raise 'memory=' in %UserProfile%\\.wslconfig)"
fi

disk_gb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
disk_gb="${disk_gb:-0}"
if (( disk_gb >= MIN_DISK_GB )); then
  pass "disk(\$HOME)" "${disk_gb} GB free"
else
  warn "disk(\$HOME)" "${disk_gb} GB free < ${MIN_DISK_GB} GB"
fi

pass "cpus" "$(nproc 2>/dev/null || echo '?') logical CPUs"

if command -v python3 >/dev/null 2>&1; then
  pyv="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
  pymm="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  case "$pymm" in
    3.9|3.10|3.11|3.12) pass "python3" "$pyv ($(command -v python3))" ;;
    *) fail "python3" "$pyv not in 3.9-3.12 (MemryX SDK requirement); use python3.11 -m venv ~/mx" ;;
  esac
else
  fail "python3" "not found"
fi

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
  pass "venv-active" "$VIRTUAL_ENV"
else
  warn "venv-active" "no venv active; recommended: python3.11 -m venv ~/mx && . ~/mx/bin/activate"
fi

if command -v mx_nc >/dev/null 2>&1; then
  ver="$(mx_nc --version 2>&1 | head -n 3 | tr '\n' ' ' || true)"
  pass "mx_nc" "$(command -v mx_nc) :: ${ver:-version unknown}"
else
  fail "mx_nc" "not on PATH. Install in the venv: pip install --extra-index-url https://developer.memryx.com/pip memryx"
fi

for tool in dfp_inspect mx_sim; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool" "$(command -v "$tool")"
  else
    warn "$tool" "not on PATH (part of the memryx pip package in SDK 2.2 - check the venv)"
  fi
done

if command -v python3 >/dev/null 2>&1; then
  memx_ver="$(python3 -m pip show memryx 2>/dev/null | awk -F': ' '/^Version:/ {print $2}' || true)"
  if [[ -n "$memx_ver" ]]; then pass "pip:memryx" "$memx_ver"; else warn "pip:memryx" "package not found in this python"; fi
  for mod in onnx onnxruntime numpy; do
    if python3 -c "import $mod" >/dev/null 2>&1; then
      pass "py:$mod" "$(python3 -c "import $mod; print(getattr($mod, '__version__', '?'))" 2>/dev/null)"
    else
      warn "py:$mod" "not importable (needed for ONNX checks/accuracy scripts)"
    fi
  done
fi

if command -v sha256sum >/dev/null 2>&1; then pass "sha256sum" "present"; else fail "sha256sum" "missing (coreutils)"; fi

if command -v ssh >/dev/null 2>&1; then
  ssh_host="$(ssh -G umpi 2>/dev/null | awk '/^hostname / {print $2; exit}' || true)"
  if [[ -n "$ssh_host" && "$ssh_host" != "umpi" ]]; then
    pass "ssh alias" "umpi -> $ssh_host (not contacted)"
  else
    warn "ssh alias" "Host umpi not configured in ~/.ssh/config (needed to deploy DFPs)"
  fi
else
  warn "ssh" "ssh client not found"
fi

echo "== $FAILS FAIL(s) =="
(( FAILS == 0 )) || exit 1
exit 0
