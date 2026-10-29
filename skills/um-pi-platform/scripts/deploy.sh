#!/usr/bin/env bash
# deploy.sh -- sync a source tree to the TX8, build natively on the board, optionally install.
# Runs on the dev host (WSL2 / Linux / Git Bash). Board access via the SSH alias (default umpi).
#
# Usage:
#   bash deploy.sh --name myapp [--src .] [--host umpi] [--build-type Release] [--jobs 4]
#                  [--binary build/myapp] [--install] [--yes] [--dry-run]
#
#   --name        application name (remote dir ~/src/<name>, install dir /opt/<name>) [required]
#   --src         local source tree (default: .)
#   --host        ssh alias (default: umpi)
#   --build-type  CMake build type (default: Release)
#   --jobs        parallel build jobs on the board (default: 4; use 2 if the compiler is OOM-killed)
#   --binary      built binary relative to the remote source dir (default: build/<name>)
#   --install     copy the binary to /opt/<name>/bin (sudo on the board) and, if present,
#                 <src>/systemd/<name>.service to /etc/systemd/system
#   --yes         with --install: also daemon-reload and restart the service (system change)
#   --dry-run     print the commands only
#
# Steps: 1) sync (rsync; fallback tar over ssh; last resort scp -r)  2) remote cmake configure+build
#        3) [--install] install binary/unit  4) [--install --yes] restart the service.
# The script prints every remote command before running it. It never installs packages.
set -euo pipefail

HOST="umpi"; NAME=""; SRC="."; BUILD_TYPE="Release"; JOBS="4"; BINARY=""
DO_INSTALL=0; YES=0; DRY=0

usage() { sed -n '2,24p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --src) SRC="${2:?}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:?}"; shift 2 ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --binary) BINARY="${2:?}"; shift 2 ;;
    --install) DO_INSTALL=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$NAME" ]; then echo "error: --name is required" >&2; usage; exit 2; fi
if ! printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  echo "error: --name must be [A-Za-z0-9._-]" >&2; exit 2
fi
case "$BUILD_TYPE" in Release|Debug|RelWithDebInfo|MinSizeRel) ;; *) echo "error: bad --build-type" >&2; exit 2 ;; esac
if [ ! -f "$SRC/CMakeLists.txt" ]; then echo "error: $SRC/CMakeLists.txt not found" >&2; exit 2; fi
[ -n "$BINARY" ] || BINARY="build/$NAME"

REMOTE_DIR="src/$NAME"          # relative to the remote home directory
have() { command -v "$1" >/dev/null 2>&1; }

step() { printf '\n==> %s\n' "$*"; }
run() {   # print, then execute unless --dry-run
  printf '+ %s\n' "$*"
  if [ "$DRY" = 0 ]; then "$@"; fi
}

echo "Plan:"
echo "  host=$HOST  src=$SRC  remote=~/$REMOTE_DIR  build=$BUILD_TYPE  jobs=$JOBS"
echo "  install=$([ "$DO_INSTALL" = 1 ] && echo yes || echo no)  restart-service=$([ "$DO_INSTALL" = 1 ] && [ "$YES" = 1 ] && echo yes || echo no)  dry-run=$([ "$DRY" = 1 ] && echo yes || echo no)"

step "Check SSH (key auth, no password prompts)"
if [ "$DRY" = 0 ]; then
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true; then
    echo "error: cannot reach '$HOST' with key auth. Run host_env_check and fix ~/.ssh/config." >&2
    exit 1
  fi
fi

step "Sync source to $HOST:~/$REMOTE_DIR"
run ssh "$HOST" "mkdir -p ~/$REMOTE_DIR"
if have rsync && { [ "$DRY" = 1 ] || ssh -o BatchMode=yes "$HOST" 'command -v rsync >/dev/null'; }; then
  run rsync -az --delete --exclude 'build/' --exclude '.git/' --exclude '*.o' "$SRC/" "$HOST:$REMOTE_DIR/"
elif have tar; then
  echo "(rsync unavailable; using tar over ssh -- stale remote files are not deleted)"
  printf '+ tar -C %s --exclude=./build --exclude=./.git -cf - . | ssh %s "tar -C ~/%s -xf -"\n' "$SRC" "$HOST" "$REMOTE_DIR"
  if [ "$DRY" = 0 ]; then
    tar -C "$SRC" --exclude=./build --exclude=./.git -cf - . | ssh "$HOST" "tar -C ~/$REMOTE_DIR -xf -"
  fi
else
  echo "(rsync and tar unavailable; using scp -r -- copies everything incl. build/ and .git/)"
  run scp -r -q "$SRC/." "$HOST:$REMOTE_DIR/"
fi

step "Native build on the board (auto-clamps -j on 2 GB EVT boards to avoid GCC OOM)"
run ssh "$HOST" "cd ~/$REMOTE_DIR && avail_mb=\$(awk '/^MemAvailable:/ {printf \"%d\", \$2/1024}' /proc/meminfo 2>/dev/null || echo 2048) && j=$JOBS && if [ \"\$avail_mb\" -lt 1500 ] && [ \"\$j\" -gt 2 ]; then echo \"[deploy] MemAvailable=\${avail_mb}MB (<1500MB): clamping build jobs from \$j to 2 to prevent OOM\"; j=2; fi && cmake -S . -B build -DCMAKE_BUILD_TYPE=$BUILD_TYPE && cmake --build build -j\$j"
run ssh "$HOST" "ls -l ~/$REMOTE_DIR/$BINARY && file ~/$REMOTE_DIR/$BINARY 2>/dev/null || true"

if [ "$DO_INSTALL" = 0 ]; then
  echo
  echo "Built. Not installed (pass --install). Run manually: ssh $HOST '~/$REMOTE_DIR/$BINARY --help'"
  exit 0
fi

step "Install binary to /opt/$NAME/bin (sudo on the board; you may be asked for the board password)"
run ssh -t "$HOST" "sudo install -D -m 0755 ~/$REMOTE_DIR/$BINARY /opt/$NAME/bin/$NAME"
if [ -d "$SRC/config" ]; then
  echo "(config: $SRC/config exists -- NOT copied automatically to /etc/$NAME to avoid overwriting board settings;"
  echo " copy explicitly: ssh -t $HOST 'sudo install -D -m 0644 ~/$REMOTE_DIR/config/$NAME.conf /etc/$NAME/$NAME.conf')"
fi

UNIT_SRC="$SRC/systemd/$NAME.service"
RESTART_CMD="sudo systemctl daemon-reload && sudo systemctl enable $NAME && sudo systemctl restart $NAME && systemctl status $NAME --no-pager -n 20"
if [ -f "$UNIT_SRC" ]; then
  step "Install systemd unit $NAME.service"
  run ssh -t "$HOST" "sudo install -m 0644 ~/$REMOTE_DIR/systemd/$NAME.service /etc/systemd/system/$NAME.service"
else
  echo "(no $UNIT_SRC; start from skills/um-pi-platform/assets/systemd/tx8-app.service)"
fi

if [ "$YES" = 1 ]; then
  step "Restart service $NAME (--yes given)"
  run ssh -t "$HOST" "$RESTART_CMD"
  run ssh "$HOST" "journalctl -u $NAME -n 50 --no-pager"
else
  echo
  echo "WARNING: service not restarted. Restarting changes the running system; re-run with --install --yes,"
  echo "or run manually: ssh -t $HOST '$RESTART_CMD'"
fi
