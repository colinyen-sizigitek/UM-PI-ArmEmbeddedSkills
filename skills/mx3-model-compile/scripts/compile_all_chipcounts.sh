#!/usr/bin/env bash
# compile_all_chipcounts.sh - compile one ONNX model to MemryX DFPs for several MX3 chip counts,
# with logs, sha256 hashes and a manifest.json. Runs on the x86 dev machine (WSL2/Linux) inside
# the MemryX SDK venv. Does not install anything.
#
# Usage:
#   bash compile_all_chipcounts.sh -m MODEL.onnx -s H,W,C [options] [-- extra mx_nc args]
#
# Required:
#   -m, --model FILE        exported ONNX (static shapes, batch 1)
#   -s, --input-shape H,W,C NHWC input shape WITHOUT batch, passed to mx_nc -is (e.g. 640,640,3)
# Options:
#   -n, --name NAME         artifact name (default: model file basename), e.g. yolo26n-pvc3-640x640
#   -v, --version X.Y.Z     artifact version (default 0.0.0-dev)
#   -o, --out DIR           output dir (default ./models/NAME/VERSION); must not exist unless --force
#   --chips "LIST"          chip counts to build (default "1 2 3 4"); 1 and 3 are flagged unverified
#   --effort E              mx_nc -e: lazy|normal|hard (default normal)
#   --classes a,b,c         class names in output order (manifest)
#   --task T                manifest task field (default detect)
#   --norm-scale S          input scale for the manifest (default 1/255); mean 0, std 1, RGB assumed
#   --force                 allow writing into an existing output dir
#   --dry-run               print the mx_nc commands only
#   --allow-arm             allow running on aarch64 (NOT recommended: compile on x86, not the board)
#   -h, --help              this help
#   --                      everything after this is appended to every mx_nc call
#                           (e.g. -- --autocrop  or  -- --outputs "a,b" --input_format FP32)
#
# Produces in OUT: NAME_c<N>.dfp (+ NAME_c<N>_pre/_post.onnx if mx_nc cropped), logs/compile_c<N>.log,
# logs/dfp_inspect_c<N>.txt, logs/env.txt, SHA256SUMS, manifest.json.
# Exit: 0 all requested chip counts compiled, 1 at least one failed, 2 usage/environment error.
#
# Note: MemryX documents that on the 4-chip M.2 only DFPs compiled for 2 or 4 chips run directly
# ("Test with fewer chips" tutorial). c1/c3 DFPs are built for evaluation and marked
# verified_on_board=false; confirm on TX8 before use (skill mx3-runtime-integration).
set -euo pipefail

MODEL=""; SHAPE=""; NAME=""; VERSION="0.0.0-dev"; OUT=""; CHIPS="1 2 3 4"; EFFORT="normal"
CLASSES=""; TASK="detect"; NORM_SCALE="0.00392156862745098"; FORCE=0; DRYRUN=0; ALLOW_ARM=0
EXTRA=()

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL="${2:?}"; shift 2 ;;
    -s|--input-shape) SHAPE="${2:?}"; shift 2 ;;
    -n|--name) NAME="${2:?}"; shift 2 ;;
    -v|--version) VERSION="${2:?}"; shift 2 ;;
    -o|--out) OUT="${2:?}"; shift 2 ;;
    --chips) CHIPS="${2:?}"; shift 2 ;;
    --effort) EFFORT="${2:?}"; shift 2 ;;
    --classes) CLASSES="${2:?}"; shift 2 ;;
    --task) TASK="${2:?}"; shift 2 ;;
    --norm-scale) NORM_SCALE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --allow-arm) ALLOW_ARM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODEL" ]] || { usage >&2; die "--model is required"; }
[[ -f "$MODEL" ]] || die "model not found: $MODEL"
[[ "$SHAPE" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || die "--input-shape must be H,W,C (NHWC, no batch), got '$SHAPE'"
[[ "$EFFORT" =~ ^(lazy|normal|hard)$ ]] || die "--effort must be lazy|normal|hard"
[[ -n "${CHIPS// /}" ]] || die "--chips must not be empty"
for c in $CHIPS; do [[ "$c" =~ ^[1-4]$ ]] || die "--chips values must be 1..4, got '$c'"; done

arch="$(uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  if (( ALLOW_ARM )); then
    echo "WARNING: running on $arch. Team rule: compile on the x86 dev machine, not on the TX8 board." >&2
  else
    die "arch $arch: compile on the x86 dev machine (WSL2/Linux). Use --allow-arm to override."
  fi
fi
command -v mx_nc >/dev/null 2>&1 || die "mx_nc not on PATH (activate the MemryX venv, e.g. . ~/mx/bin/activate)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"

MODEL_ABS="$(cd "$(dirname "$MODEL")" && pwd)/$(basename "$MODEL")"
[[ -n "$NAME" ]] || NAME="$(basename "$MODEL" .onnx)"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--name may contain only letters, digits, . _ -"
[[ -n "$OUT" ]] || OUT="./models/$NAME/$VERSION"
if [[ -e "$OUT" && $FORCE -eq 0 && $DRYRUN -eq 0 ]]; then
  die "output dir exists: $OUT (bump --version or pass --force)"
fi

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

EXTRA_STR=""
if (( ${#EXTRA[@]} )); then EXTRA_STR="$(printf '%q ' "${EXTRA[@]}")"; EXTRA_STR="${EXTRA_STR% }"; fi

if (( DRYRUN )); then
  for c in $CHIPS; do
    printf 'mx_nc -vv -m %q -is %q -c %s -e %s --dfp_fname %q %s\n' \
      "$MODEL_ABS" "$SHAPE" "$c" "$EFFORT" "${NAME}_c${c}.dfp" "$EXTRA_STR"
  done
  exit 0
fi

mkdir -p "$OUT/logs"
OUT_ABS="$(cd "$OUT" && pwd)"
ENV_LOG="$OUT_ABS/logs/env.txt"
{
  echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "nproc: $(nproc 2>/dev/null || echo '?')"
  grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null || true
  echo "python: $(python3 --version 2>&1 || true)"
  echo "mx_nc --version:"; mx_nc --version 2>&1 || true
  echo "pip memryx: $(python3 -m pip show memryx 2>/dev/null | awk -F': ' '/^Version:/ {print $2}' || true)"
} > "$ENV_LOG"
MXNC_VERSION="$(mx_nc --version 2>&1 | head -n 1 || true)"
PY_VERSION="$(python3 --version 2>&1 | awk '{print $2}' || true)"
ONNX_SHA="$(sha256sum "$MODEL_ABS" | awk '{print $1}')"
HOST_DESC="$(uname -s) $(uname -m)"
grep -qi microsoft /proc/version 2>/dev/null && HOST_DESC="WSL2 $HOST_DESC"

declare -a ENTRIES=()
FAILED=0
for c in $CHIPS; do
  dfp="${NAME}_c${c}.dfp"
  work="$OUT_ABS/.work_c${c}"
  log="$OUT_ABS/logs/compile_c${c}.log"
  rm -rf "$work"; mkdir -p "$work"
  touch "$work/.stamp"
  cmd=(mx_nc -vv -m "$MODEL_ABS" -is "$SHAPE" -c "$c" -e "$EFFORT" --dfp_fname "$dfp")
  if (( ${#EXTRA[@]} )); then cmd+=("${EXTRA[@]}"); fi
  if [[ "$c" == "1" || "$c" == "3" ]]; then
    echo "WARNING: c=$c: MemryX documents only 2/4-chip DFPs for the 4-chip M.2; result marked unverified." >&2
  fi
  echo "== [c=$c] $(printf '%q ' "${cmd[@]}")" | tee "$log"
  start=$SECONDS
  set +e
  ( cd "$work" && "${cmd[@]}" ) 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  set -e
  secs=$(( SECONDS - start ))
  status="failed"; sha=""; size=0; extras=""
  if [[ $rc -eq 0 && -f "$work/$dfp" ]]; then
    mv "$work/$dfp" "$OUT_ABS/$dfp"
    # Cropped pre/post models: look in the work dir and (in case mx_nc writes them next to the
    # source model) in the model's directory, only files created during this compile.
    while IFS= read -r f; do
      suffix="${f##*_}"                                  # pre.onnx | post.onnx
      cp -p "$f" "$OUT_ABS/${NAME}_c${c}_${suffix}"
      extras+="${extras:+, }\"${NAME}_c${c}_${suffix}\""
      echo "== [c=$c] cropped model: $f -> ${NAME}_c${c}_${suffix}" | tee -a "$log"
    done < <(find "$work" "$(dirname "$MODEL_ABS")" -maxdepth 1 -type f -newer "$work/.stamp" \
               \( -name '*_pre.onnx' -o -name '*_post.onnx' \) 2>/dev/null | sort -u)
    sha="$(sha256sum "$OUT_ABS/$dfp" | awk '{print $1}')"
    size="$(stat -c %s "$OUT_ABS/$dfp")"
    status="ok"
    if command -v dfp_inspect >/dev/null 2>&1; then
      dfp_inspect "$OUT_ABS/$dfp" > "$OUT_ABS/logs/dfp_inspect_c${c}.txt" 2>&1 || true
    fi
    echo "== [c=$c] OK  $dfp  ${size} bytes  sha256=$sha  ${secs}s" | tee -a "$log"
  else
    FAILED=1
    echo "== [c=$c] FAILED (rc=$rc) after ${secs}s - see $log" | tee -a "$log" >&2
  fi
  rm -rf "$work"
  verified="false"
  ENTRIES+=("    { \"chip_count\": $c, \"file\": $( [[ $status == ok ]] && printf '"%s"' "$dfp" || printf 'null' ), \"sha256\": $( [[ -n $sha ]] && printf '"%s"' "$sha" || printf 'null' ), \"size_bytes\": $size, \"compile_seconds\": $secs, \"status\": \"$status\", \"extra_files\": [${extras}], \"verified_on_board\": $verified }")
done

( cd "$OUT_ABS" && { ls -1 ./*.dfp ./*.onnx 2>/dev/null || true; } | sed 's|^\./||' | xargs -r sha256sum > SHA256SUMS )

classes_json=""
if [[ -n "$CLASSES" ]]; then
  IFS=',' read -r -a cls_arr <<< "$CLASSES"
  for cl in "${cls_arr[@]}"; do classes_json+="${classes_json:+, }\"$(json_esc "$cl")\""; done
fi
IFS=',' read -r H W C <<< "$SHAPE"
entries_json=""
for e in "${ENTRIES[@]}"; do entries_json+="${entries_json:+,$'\n'}$e"; done

cat > "$OUT_ABS/manifest.json" <<EOF
{
  "schema_version": "1.0",
  "name": "$(json_esc "$NAME")",
  "version": "$(json_esc "$VERSION")",
  "created_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "created_by": "$(json_esc "${USER:-unknown}")",
  "model": {
    "task": "$(json_esc "$TASK")",
    "onnx_file": "$(json_esc "$(basename "$MODEL_ABS")")",
    "onnx_sha256": "$ONNX_SHA",
    "family": null, "variant": null, "framework": null, "framework_version": null,
    "export_args": null, "license": null
  },
  "classes": [${classes_json}],
  "input": {
    "shape_nhwc": [$H, $W, $C],
    "dtype": "float32",
    "color_order": "RGB",
    "normalization": { "scale": $NORM_SCALE, "mean": [0, 0, 0], "std": [1, 1, 1] },
    "resize": "letterbox",
    "pad_value": 114
  },
  "outputs": [],
  "host_post": null,
  "compiler": {
    "mx_nc_version": "$(json_esc "$MXNC_VERSION")",
    "python": "$(json_esc "$PY_VERSION")",
    "host": "$(json_esc "$HOST_DESC")",
    "effort": "$EFFORT",
    "extra_args": "$(json_esc "$EXTRA_STR")"
  },
  "dfps": [
$entries_json
  ],
  "frequency": null,
  "accuracy": null
}
EOF

echo "Manifest: $OUT_ABS/manifest.json"
echo "Fill in: model.family/variant/framework/export_args/license, outputs (see logs/dfp_inspect_c*.txt), host_post, frequency, accuracy."
if (( FAILED )); then echo "At least one chip count failed - see logs/." >&2; exit 1; fi
exit 0
