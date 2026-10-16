#!/usr/bin/env bash
# host_env_check.sh -- read-only check of a Linux / WSL2 dev host for TX8 / MX3 development.
#
# Usage: bash host_env_check.sh [--host umpi] [--skip-ssh] [--help]
#
# Checks: OS release (Ubuntu 22.04 recommended), WSL detection, RAM, AVX2, git, cmake >= 3.16,
# python3, ssh client, ssh key, ~/.ssh/config "Host <alias>", key auth to the board with timeout,
# mx_nc, optional aarch64-linux-gnu-g++-11, rsync.
# Prints a table OK / MISSING / FAIL / WARN / SKIP and advice. Never installs or changes anything.
# Exit code 0 if all required items are OK or WARN, 1 otherwise.
set -euo pipefail

HOST_ALIAS="umpi"
SKIP_SSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_ALIAS="${2:?--host needs a value}"; shift 2 ;;
    --skip-ssh) SKIP_SSH=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

ROWS=()
BAD=0
# add <item> <status> <required:yes|opt> <detail> <advice>
add() {
  ROWS+=("$1|$2|$3|$4|$5")
  if [ "$3" = "yes" ] && { [ "$2" = "MISSING" ] || [ "$2" = "FAIL" ]; }; then BAD=$((BAD + 1)); fi
}

ver_ge() {  # ver_ge 3.22.1 3.16 -> true if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

echo "TX8 dev host check (read-only) - $(date -Is 2>/dev/null || date)"
echo

# OS
os="unknown"
if [ -r /etc/os-release ]; then os="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"; fi
if grep -qi microsoft /proc/version 2>/dev/null; then is_wsl="yes (WSL)"; else is_wsl="no"; fi
case "$os" in
  *"22.04"*) add "OS" "OK" "yes" "$os; WSL: $is_wsl" "" ;;
  *) add "OS" "WARN" "yes" "$os; WSL: $is_wsl" "Ubuntu 22.04 recommended (matches board glibc 2.35)" ;;
esac
if [ "$(uname -m)" != "x86_64" ]; then
  add "Arch" "WARN" "opt" "$(uname -m)" "mx_nc supports x86_64 (AVX2) or ARM64 Linux; never compile on the TX8"
fi

# RAM
mem_kb="$(awk '/^MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$(( mem_kb / 1024 / 1024 ))
if [ "$mem_gb" -ge 15 ]; then add "RAM" "OK" "yes" "${mem_gb} GB" ""
elif [ "$mem_gb" -ge 7 ]; then add "RAM" "WARN" "yes" "${mem_gb} GB" "16 GB recommended (WSL: raise memory= in %UserProfile%\\.wslconfig)"
else add "RAM" "FAIL" "yes" "${mem_gb} GB" ">= 8 GB needed for mx_nc"; fi

# AVX2
if [ "$(uname -m)" = "x86_64" ]; then
  if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then add "CPU AVX2" "OK" "yes" "present" ""
  else add "CPU AVX2" "FAIL" "yes" "not reported" "mx_nc needs AVX2 on x86"; fi
fi

# git
if have git; then
  add "git" "OK" "yes" "$(git --version)" ""
else add "git" "MISSING" "yes" "" "sudo apt install git (engineer runs)"; fi

# cmake
if have cmake; then
  cv="$(cmake --version | head -1 | awk '{print $3}')"
  if ver_ge "$cv" "3.16"; then add "cmake" "OK" "yes" "$cv" ""; else add "cmake" "FAIL" "yes" "$cv" "CMake >= 3.16 required"; fi
else add "cmake" "MISSING" "yes" "" "sudo apt install cmake (engineer runs)"; fi

# python3
if have python3; then
  pv="$(python3 --version 2>&1)"
  add "python3" "OK" "yes" "$pv" "mx_nc needs Python 3.9-3.12 in a venv"
else add "python3" "MISSING" "yes" "" "sudo apt install python3 python3-venv (engineer runs)"; fi

# ssh client + key
if have ssh; then add "ssh client" "OK" "yes" "$(ssh -V 2>&1 | head -1)" ""
else add "ssh client" "MISSING" "yes" "" "sudo apt install openssh-client"; fi
keys=""
for k in id_ed25519 id_ecdsa id_rsa; do
  if [ -f "$HOME/.ssh/$k" ]; then keys="$keys $k"; fi
done
if [ -n "$keys" ]; then
  perm="$(stat -c %a "$HOME/.ssh/$(echo $keys | awk '{print $1}')" 2>/dev/null || echo '?')"
  if [ "$perm" = "600" ] || [ "$perm" = "400" ]; then add "SSH key" "OK" "yes" "${keys# } (mode $perm)" ""
  else add "SSH key" "WARN" "yes" "${keys# } (mode $perm)" "chmod 600 the private key (keys under /mnt/c have wrong modes)"; fi
else add "SSH key" "MISSING" "yes" "" "ssh-keygen -t ed25519; ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<board>"; fi

alias_ok=0
if [ -f "$HOME/.ssh/config" ] && grep -Eq "^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?${HOST_ALIAS}([[:space:]]|\$)" "$HOME/.ssh/config"; then
  alias_ok=1; add "ssh alias $HOST_ALIAS" "OK" "yes" "~/.ssh/config" ""
else
  add "ssh alias $HOST_ALIAS" "MISSING" "yes" "no 'Host $HOST_ALIAS' in ~/.ssh/config" "Add Host block (WSL does not read the Windows ssh config); see dev-host-setup.md 2.7"
fi

if [ "$SKIP_SSH" = 1 ]; then add "$HOST_ALIAS reachable" "SKIP" "opt" "--skip-ssh" ""
elif [ "$alias_ok" = 0 ] || ! have ssh; then add "$HOST_ALIAS reachable" "SKIP" "yes" "alias or ssh missing" ""
else
  tmo=""; have timeout && tmo="timeout 20"
  if err="$($tmo ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "$HOST_ALIAS" true 2>&1 </dev/null)"; then
    add "$HOST_ALIAS reachable" "OK" "yes" "key auth works" ""
  else
    first="$(printf '%s' "$err" | head -1)"
    adv="ssh -v $HOST_ALIAS true"
    case "$first" in
      *"Permission denied"*) adv="copy your public key: ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<board>" ;;
      *"Host key verification"*) adv="host key unknown/changed: connect once interactively, or ssh-keygen -R <host> after confirming a re-flash" ;;
      *"timed out"*|*"No route"*|*"resolve"*) adv="check HostName/IP and network" ;;
    esac
    add "$HOST_ALIAS reachable" "FAIL" "yes" "${first:-timeout}" "$adv"
  fi
fi

# mx_nc
mxnc="$(command -v mx_nc 2>/dev/null || true)"
if [ -z "$mxnc" ]; then
  for p in "$HOME/mx/bin/mx_nc" "$HOME/.venv/bin/mx_nc" "$HOME/memryx/bin/mx_nc"; do
    if [ -x "$p" ]; then mxnc="$p"; break; fi
  done
fi
if [ -n "$mxnc" ]; then
  mv="$("$mxnc" --version 2>&1 | head -1 || true)"
  add "mx_nc" "OK" "yes" "$mxnc ${mv}" "match SDK version to the board runtime (ssh $HOST_ALIAS 'dpkg -l | grep memx')"
else
  add "mx_nc" "MISSING" "yes" "" "python3 -m venv ~/mx && ~/mx/bin/pip install --extra-index-url https://developer.memryx.com/pip memryx"
fi

# optional cross compiler and rsync
if have aarch64-linux-gnu-g++-11; then add "aarch64 g++-11" "OK" "opt" "$(aarch64-linux-gnu-g++-11 --version | head -1)" ""
else add "aarch64 g++-11" "SKIP" "opt" "not installed (optional)" "cross-compile only: sudo apt install g++-11-aarch64-linux-gnu"; fi
if [ -n "${TX8_SYSROOT:-}" ]; then
  if [ -d "$TX8_SYSROOT/usr/include" ]; then add "TX8_SYSROOT" "OK" "opt" "$TX8_SYSROOT" ""
  else add "TX8_SYSROOT" "WARN" "opt" "$TX8_SYSROOT has no usr/include" "pull sysroot from the board (build-and-deploy.md section 6)"; fi
fi
if have rsync; then add "rsync" "OK" "opt" "$(rsync --version | head -1)" ""
else add "rsync" "SKIP" "opt" "not installed" "deploy.sh falls back to tar over ssh"; fi

# report
printf '%-22s %-8s %-4s %s\n' "Item" "Status" "Req" "Detail / advice"
printf '%-22s %-8s %-4s %s\n' "----" "------" "---" "---------------"
for r in "${ROWS[@]}"; do
  IFS='|' read -r item st req det adv <<< "$r"
  line="$det"
  if [ -n "$adv" ]; then line="${line:+$line -> }$adv"; fi
  printf '%-22s %-8s %-4s %s\n' "$item" "$st" "$req" "$line"
done
echo
if [ "$BAD" -gt 0 ]; then
  echo "$BAD required item(s) need attention. Nothing was installed or changed."
  exit 1
fi
echo "All required items OK. Nothing was installed or changed."
