#!/usr/bin/env bash
# install.sh -- install the TX8 / MX3 Agent Skills into Claude Code, OpenAI Codex and/or Google Antigravity.
# Works on Linux, WSL and Git Bash. Copies folders (no symlinks).
#
# Usage:
#   bash install/install.sh [--target claude|codex|antigravity|all] [--scope project|user]
#                           [--project-path DIR] [--skills a,b,c] [--dry-run] [--force]
#
# Destinations
#   project scope (default):  Claude -> <proj>/.claude/skills/<name>
#                             Codex, Antigravity -> <proj>/.agents/skills/<name>
#                             + merge shared/AGENTS.tx8.md into <proj>/AGENTS.md (managed block
#                               "<!-- tx8-skills:begin" .. "<!-- tx8-skills:end -->": replace or append)
#                             + Claude: ensure <proj>/CLAUDE.md contains a line "@AGENTS.md"
#   user scope:               Claude -> ~/.claude/skills, Codex -> ~/.agents/skills,
#                             Antigravity -> ~/.gemini/config/skills
#                             (older Antigravity builds: ~/.gemini/antigravity/skills -- not written here)
#                             Always-on rules are not installed in user scope; merge per project.
#
# Each installed skill folder gets a marker file ".tx8-skills". An existing destination folder is
# overwritten only if it has the marker or --force is given; otherwise it is skipped with a warning.
# Exit codes: 0 ok, 2 usage error, 3 some skills skipped.
set -euo pipefail

TARGET="all"; SCOPE="project"; PROJECT_PATH=""; SKILLS=""; DRY=0; FORCE=0
SUITE_VERSION="1.0.0"
MARKER=".tx8-skills"
BEGIN_TAG='<!-- tx8-skills:begin'
END_TAG='<!-- tx8-skills:end -->'

usage() { sed -n '2,24p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?}"; shift 2 ;;
    --scope) SCOPE="${2:?}"; shift 2 ;;
    --project-path) PROJECT_PATH="${2:?}"; shift 2 ;;
    --skills) SKILLS="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$TARGET" in claude|codex|antigravity|all) ;; *) echo "error: --target must be claude|codex|antigravity|all" >&2; exit 2 ;; esac
case "$SCOPE" in project|user) ;; *) echo "error: --scope must be project|user" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_ROOT="$REPO_ROOT/skills"
SHARED_AGENTS="$REPO_ROOT/shared/AGENTS.tx8.md"
if [ -f "$REPO_ROOT/VERSION" ]; then SUITE_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"; fi
[ -d "$SKILLS_ROOT" ] || { echo "error: $SKILLS_ROOT not found" >&2; exit 2; }

# ---- skills -------------------------------------------------------------------------------------
AVAILABLE=()
for d in "$SKILLS_ROOT"/*/; do
  if [ -f "${d}SKILL.md" ]; then AVAILABLE+=("$(basename "$d")"); fi
done
SELECTED=()
if [ -n "$SKILLS" ]; then
  IFS=',' read -r -a req <<< "$SKILLS"
  for s in "${req[@]}"; do
    s="$(printf '%s' "$s" | tr -d '[:space:]')"
    [ -n "$s" ] || continue
    if [ -f "$SKILLS_ROOT/$s/SKILL.md" ]; then SELECTED+=("$s"); else echo "WARNING: skill '$s' not found (skipped)" >&2; fi
  done
else
  SELECTED=("${AVAILABLE[@]}")
fi
[ "${#SELECTED[@]}" -gt 0 ] || { echo "error: no skills to install" >&2; exit 2; }

# ---- destinations ----------------------------------------------------------------------------
if [ "$TARGET" = all ]; then TARGETS=(claude codex antigravity); else TARGETS=("$TARGET"); fi

if [ "$SCOPE" = project ]; then
  [ -n "$PROJECT_PATH" ] || PROJECT_PATH="$(pwd)"
  [ -d "$PROJECT_PATH" ] || { echo "error: --project-path does not exist: $PROJECT_PATH" >&2; exit 2; }
  PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
fi

ROOTS=(); LABELS=()
add_root() {  # add_root <dir> <agent>  (dedupe: codex+antigravity share .agents/skills in project scope)
  local i
  for i in "${!ROOTS[@]}"; do
    if [ "${ROOTS[$i]}" = "$1" ]; then LABELS[$i]="${LABELS[$i]}+$2"; return 0; fi
  done
  ROOTS+=("$1"); LABELS+=("$2")
}
for t in "${TARGETS[@]}"; do
  if [ "$SCOPE" = project ]; then
    if [ "$t" = claude ]; then add_root "$PROJECT_PATH/.claude/skills" "$t"; else add_root "$PROJECT_PATH/.agents/skills" "$t"; fi
  else
    case "$t" in
      claude) add_root "$HOME/.claude/skills" "$t" ;;
      codex) add_root "$HOME/.agents/skills" "$t" ;;
      antigravity) add_root "$HOME/.gemini/config/skills" "$t" ;;
    esac
  fi
done

mode="INSTALL"; [ "$DRY" = 0 ] || mode="DRY RUN (nothing is written)"
echo "TX8 skills installer $SUITE_VERSION  [$mode]"
echo "  source : $SKILLS_ROOT"
echo "  scope  : $SCOPE${PROJECT_PATH:+  ($PROJECT_PATH)}"
echo "  targets: ${TARGETS[*]}"
echo "  skills : ${SELECTED[*]}"
echo

SUMMARY=()
SKIPPED=0
row() { SUMMARY+=("$1|$2|$3|$4"); }

skill_version() {
  local v
  v="$(grep -E '^[[:space:]]+version:' "$1/SKILL.md" | head -1 | sed -E 's/^[[:space:]]+version:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' || true)"
  printf '%s' "${v:-unknown}"
}

# ---- copy skills ------------------------------------------------------------------------------
for i in "${!ROOTS[@]}"; do
  root="${ROOTS[$i]}"; agent="${LABELS[$i]}"
  for name in "${SELECTED[@]}"; do
    src="$SKILLS_ROOT/$name"; dst="$root/$name"; action="install"
    if [ -e "$dst" ]; then
      if [ -f "$dst/$MARKER" ]; then action="update"
      elif [ "$FORCE" = 1 ]; then action="overwrite (--force)"
      else
        echo "WARNING: $dst exists and was not installed by tx8-skills; skipped (use --force)" >&2
        row "$agent" "$name" "SKIPPED (unmanaged)" "$dst"; SKIPPED=$((SKIPPED + 1)); continue
      fi
    fi
    if [ "$DRY" = 1 ]; then row "$agent" "$name" "would $action" "$dst"; continue; fi
    rm -rf -- "$dst"
    mkdir -p "$root"
    cp -R -- "$src" "$dst"
    {
      echo "# tx8-skills marker: this folder is managed by ArmEmbeddedSkills/install (safe to overwrite by the installer)"
      echo "suite_version=$SUITE_VERSION"
      echo "skill=$name"
      echo "skill_version=$(skill_version "$src")"
      echo "source=$src"
      echo "agent=$agent"
      echo "scope=$SCOPE"
      echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$dst/$MARKER"
    row "$agent" "$name" "$action" "$dst"
  done
done

# ---- always-on rules (project scope) ---------------------------------------------------------
if [ "$SCOPE" = project ]; then
  [ -f "$SHARED_AGENTS" ] || { echo "error: missing $SHARED_AGENTS" >&2; exit 2; }
  tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
  tr -d '\r' < "$SHARED_AGENTS" > "$tmpdir/src.md"
  sed -n "/$BEGIN_TAG/,/$END_TAG/p" "$tmpdir/src.md" > "$tmpdir/block.md"
  if ! grep -q "$BEGIN_TAG" "$tmpdir/block.md" || ! grep -qF "$END_TAG" "$tmpdir/block.md"; then
    echo "error: shared/AGENTS.tx8.md lacks the tx8-skills begin/end markers" >&2; exit 2
  fi
  title="$(awk -v b="$BEGIN_TAG" 'index($0,b){exit} /^# /{print; exit}' "$tmpdir/src.md")"

  agents="$PROJECT_PATH/AGENTS.md"
  if [ ! -f "$agents" ]; then
    a_action="create"
    cp "$tmpdir/src.md" "$tmpdir/new.md"
  elif grep -qF "$BEGIN_TAG" "$agents"; then
    if ! awk -v b="$BEGIN_TAG" -v e="$END_TAG" 'index($0,b){s=1} s&&index($0,e){f=1} END{exit !f}' "$agents"; then
      echo "WARNING: $agents has the begin marker but no end marker; not modified. Fix by hand." >&2
      a_action="SKIPPED (broken markers)"
    else
      a_action="replace block"
      # Keep the file's own line endings: detect CRLF and re-add CR to inserted lines.
      cr=""; if grep -q $'\r' "$agents"; then cr=$'\r'; fi
      awk -v b="$BEGIN_TAG" -v e="$END_TAG" -v blk="$tmpdir/block.md" -v cr="$cr" '
        !done && index($0, b) { while ((getline l < blk) > 0) print l cr; skip = 1; done = 1 }
        skip { if (index($0, e)) skip = 0; next }
        { print }
      ' "$agents" > "$tmpdir/new.md"
      if cmp -s "$agents" "$tmpdir/new.md"; then a_action="unchanged"; fi
    fi
  else
    a_action="append block"
    cp "$agents" "$tmpdir/new.md"
    if [ -s "$tmpdir/new.md" ] && [ -n "$(tail -c1 "$tmpdir/new.md")" ]; then echo >> "$tmpdir/new.md"; fi
    { echo; if [ -n "$title" ]; then echo "$title"; echo; fi; cat "$tmpdir/block.md"; } >> "$tmpdir/new.md"
  fi
  if [ "$DRY" = 1 ]; then row "all" "AGENTS.md" "would $a_action" "$agents"
  else
    case "$a_action" in create|"replace block"|"append block") cp "$tmpdir/new.md" "$agents" ;; esac
    row "all" "AGENTS.md" "$a_action" "$agents"
  fi

  case " ${TARGETS[*]} " in
    *" claude "*)
      claude_md="$PROJECT_PATH/CLAUDE.md"
      if [ ! -f "$claude_md" ]; then
        c_action="create"
        if [ "$DRY" = 0 ]; then
          printf '%s\n%s\n' "<!-- Claude Code: import the shared project rules (incl. TX8/MX3 rules) from AGENTS.md -->" "@AGENTS.md" > "$claude_md"
        fi
      elif tr -d '\r' < "$claude_md" | grep -Eq '^[[:space:]]*@AGENTS\.md[[:space:]]*$'; then
        c_action="unchanged (has @AGENTS.md)"
      else
        c_action="append @AGENTS.md"
        if [ "$DRY" = 0 ]; then
          if [ -s "$claude_md" ] && [ -n "$(tail -c1 "$claude_md")" ]; then echo >> "$claude_md"; fi
          printf '\n@AGENTS.md\n' >> "$claude_md"
        fi
      fi
      if [ "$DRY" = 1 ]; then row "claude" "CLAUDE.md" "would $c_action" "$claude_md"; else row "claude" "CLAUDE.md" "$c_action" "$claude_md"; fi
      ;;
  esac
fi

# ---- summary ---------------------------------------------------------------------------------
echo
printf '%-26s %-20s %-28s %s\n' "Agent" "Item" "Action" "Path"
printf '%-26s %-20s %-28s %s\n' "-----" "----" "------" "----"
for r in "${SUMMARY[@]}"; do
  IFS='|' read -r a it ac p <<< "$r"
  printf '%-26s %-20s %-28s %s\n' "$a" "$it" "$ac" "$p"
done
echo
if [ "$SCOPE" = user ]; then
  echo "NOTE: user scope installs skills only. The always-on rules (shared/AGENTS.tx8.md) must be"
  echo "      merged into each project: re-run with --scope project --project-path <dir>."
fi
if [ "$DRY" = 1 ]; then echo "Dry run complete. Nothing was written."; else echo "Done. Restart the agent (or start a new session) to load the skills."; fi
if [ "$SKIPPED" -gt 0 ]; then exit 3; fi
exit 0
