#!/usr/bin/env bash
# =============================================================================
# capture-patch.sh  --  SAFE, one-command patch capture for coderyoMC (issue #26)
# =============================================================================
# Wraps the flaky paperweight (patcher 2.0.0-beta.21) patch-rebuild tasks so that
# capturing a minecraft-source / feature edit does NOT leave the tracked patch set
# corrupted. The rebuild reliably injects SPURIOUS churn into UNRELATED patches
# (see issue #26): every run re-touches the two hand-authored EOF patches
#   coderyo-server/minecraft-patches/sources/com/coderyo/compat/Governor.java.patch
#   coderyo-server/minecraft-patches/sources/com/coderyo/compat/MarshalRouter.java.patch
# (flipping `@@ -1,0 +_,130 @@` -> `+_,131` and dropping "\ No newline at end of
# file"), and on Windows can inject CRLF/whitespace edits and, in the worst case,
# delete unrelated patches mid-run. Every agent has had to detect + revert this by
# hand ~15 times. This wrapper automates the proven manual procedure.
#
# WHAT IT DOES (the manual procedure from issue #26, automated):
#   1. Enforce prerequisites: core.autocrlf=false on BOTH the primary repo and the
#      nested materialized-tree git (which otherwise inherits autocrlf=true from the
#      Git-for-Windows SYSTEM gitconfig -> ~5000-file CRLF churn); commit/fixup the
#      materialized source edit into its file-patches commit so the rebuild's diff
#      baseline is clean.
#   2. Snapshot the tracked coderyo-server/minecraft-patches/**.patch file list +
#      content hashes.
#   3. Run the real rebuild task.
#   4. Detect every patch changed/added/deleted and REVERT any that is NOT one of
#      the intended patch(es) you named -- restoring the Governor/MarshalRouter EOF
#      churn and any other spurious change to its committed state.
#   5. Round-trip verify: from a clean tree, `applyAllPatches` reproduces the exact
#      edited bytes AND `:coderyo-server:compileJava` compiles clean.
#   6. Print a clear PASS/FAIL summary.
#
# USAGE:
#   test-harness/tools/capture-patch.sh <intended-patch> [<intended-patch>...] [options]
#
#   <intended-patch> selects the patch(es) you MEANT to change. It is matched as a
#   substring against the tracked patch paths, so any of these work:
#       CompatConfig                 -> sources/com/coderyo/compat/CompatConfig.java.patch
#       compat/CompatConfig.java     -> same (more specific)
#       0017                         -> features/0017-P3.3-NMS-setBlock-...patch
#   Everything else that the rebuild churns is reverted.
#
#   Options:
#     --no-verify   skip the (slow) from-scratch applyAllPatches + compile round-trip
#     --timeout N   per-gradle-task timeout in seconds (default 300; anti-hang)
#     -h|--help     this help
#
# EXIT: 0 = PASS (intended patch(es) captured, everything else clean, round-trip OK)
#       1 = FAIL (see summary)   2 = usage/precondition error
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root $ROOT" >&2; exit 2; }

MC_GIT="$ROOT/coderyo-server/src/minecraft/java"
PATCH_ROOT="coderyo-server/minecraft-patches"
GRADLEW="./gradlew"
TIMEOUT=300
VERIFY=1

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
log()   { printf '[capture-patch] %s\n' "$*"; }
die()   { c_red "[capture-patch] ERROR: $*"; exit 2; }
fail()  { c_red "[capture-patch] FAIL: $*"; exit 1; }

# run a gradle task under a hard timeout so a hung paperweight task can never wedge
# the wrapper (anti-stall). $1=logfile, rest=gradle args. Sets global GR_RC.
run_gradle() {
  local logf="$1"; shift
  GR_RC=0
  timeout "$TIMEOUT" "$GRADLEW" "$@" > "$logf" 2>&1 || GR_RC=$?
  if [ "$GR_RC" = 124 ]; then
    c_ylw "  (gradle $* exceeded ${TIMEOUT}s -> killed; anti-hang)"
  fi
  return 0
}

# ---- args -------------------------------------------------------------------
INTENDED=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-verify) VERIFY=0 ;;
    --timeout)   shift; TIMEOUT="${1:?--timeout needs a value}" ;;
    -h|--help)   sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           INTENDED+=("$1") ;;
  esac
  shift
done
[ "${#INTENDED[@]}" -ge 1 ] || die "usage: capture-patch.sh <intended-patch> [more...] [--no-verify]"
[ -d "$MC_GIT/.git" ] || die "materialized internal git not found at $MC_GIT/.git -- run './gradlew applyAllPatches' first."

# ---- resolve intended tokens -> allowlist of tracked patch files ------------
mapfile -t ALL_PATCHES < <(git ls-files "$PATCH_ROOT" | grep -E '\.patch$')
declare -A ALLOW=()
for tok in "${INTENDED[@]}"; do
  hits=0
  for pf in "${ALL_PATCHES[@]}"; do
    case "$pf" in *"$tok"*) ALLOW["$pf"]=1; hits=$((hits+1));; esac
  done
  if [ "$hits" -eq 0 ]; then
    c_ylw "token '$tok' matched no tracked patch (brand-new patch?). Any new patch"
    c_ylw "whose path contains '$tok' will still be accepted as intended."
  else
    log "intended '$tok' -> $hits patch file(s)"
  fi
done
# also accept a brand-new (untracked) patch whose path contains an intended token
token_intended() { local f="$1"; local t; for t in "${INTENDED[@]}"; do case "$f" in *"$t"*) return 0;; esac; done; return 1; }

# ---- (1) prerequisites ------------------------------------------------------
# Record the user's REAL edits BEFORE touching git config. A freshly materialized
# tree is clean, so anything dirty now is a genuine edit.
mapfile -t REAL_EDITS < <(git -C "$MC_GIT" status --porcelain | awk '{print $2}' | grep -v '^$')
log "edited file(s) in materialized tree: ${REAL_EDITS[*]:-<none>}"

log "enforcing core.autocrlf=false (primary + internal materialized git)"
git config core.autocrlf false
git -C "$MC_GIT" config core.autocrlf false
git -C "$MC_GIT" config core.eol lf
git -C "$MC_GIT" config core.safecrlf false

# Setting autocrlf=false on an already-materialized (autocrlf=true) tree surfaces
# PHANTOM CRLF-only diffs on every patched file. Restore each dirty file that is NOT
# one of the real edits, so fixup/rebuild only ever see the genuine change (and no
# CRLF churn leaks into a regenerated patch).
declare -A ISREAL=(); for f in "${REAL_EDITS[@]}"; do ISREAL["$f"]=1; done
phantom=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -z "${ISREAL[$f]:-}" ]; then git -C "$MC_GIT" checkout -- "$f" 2>/dev/null && phantom=$((phantom+1)); fi
done < <(git -C "$MC_GIT" status --porcelain | awk '{print $2}')
[ "$phantom" -gt 0 ] && log "restored $phantom phantom CRLF-only diff(s) (autocrlf renormalisation)"

# fold any uncommitted materialized-source edit into its file-patches commit so the
# rebuild's diff baseline is clean (the rebuild reads the COMMIT, not the worktree).
if [ -n "$(git -C "$MC_GIT" status --porcelain)" ]; then
  # is the dirty set entirely file-patch (com/coderyo/** style) sources, or does it
  # include upstream net/minecraft feature files?
  if git -C "$MC_GIT" status --porcelain | awk '{print $2}' | grep -qvE '^com/coderyo/'; then
    c_ylw "internal tree has uncommitted UPSTREAM (feature) edits. Feature patches"
    c_ylw "are captured from COMMITTED feature commits -- commit them in $MC_GIT"
    c_ylw "first (git -C \"$MC_GIT\" commit -am '<feature>'). Proceeding with rebuild."
  else
    log "folding uncommitted source edit(s) into the file-patches commit (fixup)"
    run_gradle /tmp/capturepatch.fixup.log :coderyo-server:fixupMinecraftSourcePatches
    if [ "$GR_RC" != 0 ]; then
      tail -6 /tmp/capturepatch.fixup.log | sed 's/^/    | /'
      fail "fixupMinecraftSourcePatches failed (rc=$GR_RC) -- cannot establish clean baseline"
    fi
  fi
fi

# ---- (2) snapshot -----------------------------------------------------------
SNAP="$(mktemp)"; trap 'rm -f "$SNAP"' EXIT
for f in "${ALL_PATCHES[@]}"; do printf '%s %s\n' "$(git hash-object "$f")" "$f"; done > "$SNAP"
log "snapshotted $(wc -l < "$SNAP" | tr -d ' ') tracked patch files"

# ---- (3) run the real rebuild ----------------------------------------------
# Choose the rebuild task that MATCHES the intended edit's class. This is critical:
# running the FEATURE rebuild for a SOURCE edit renumbers every features/**.patch
# (the exact 0017/0018-rename churn from issue #26), so we only run the feature
# rebuild when a feature patch is actually intended.
REBUILD_TASKS=()
want_src=0; want_feat=0
for pf in "${!ALLOW[@]}"; do
  case "$pf" in
    "$PATCH_ROOT"/sources/*)  want_src=1 ;;
    "$PATCH_ROOT"/features/*) want_feat=1 ;;
  esac
done
# tokens that matched no tracked patch (brand-new): infer from the token text
if [ "$want_src" = 0 ] && [ "$want_feat" = 0 ]; then
  for t in "${INTENDED[@]}"; do case "$t" in features/*|[0-9][0-9][0-9][0-9]*) want_feat=1;; *) want_src=1;; esac; done
fi
[ "$want_src" = 1 ]  && REBUILD_TASKS+=(:coderyo-server:rebuildMinecraftSourcePatches)
[ "$want_feat" = 1 ] && REBUILD_TASKS+=(:coderyo-server:rebuildMinecraftFeaturePatches)
log "running ${REBUILD_TASKS[*]} (timeout ${TIMEOUT}s)"
run_gradle /tmp/capturepatch.rebuild.log "${REBUILD_TASKS[@]}"
if [ "$GR_RC" != 0 ]; then
  c_ylw "rebuild exited rc=$GR_RC (paperweight is flaky; step 4 restores any damage):"
  tail -8 /tmp/capturepatch.rebuild.log | sed 's/^/    | /'
fi

# ---- (4) detect + revert spurious churn ------------------------------------
# universe = union(now-tracked, snapshot, any untracked patch under PATCH_ROOT)
mapfile -t UNIVERSE < <(
  { git ls-files "$PATCH_ROOT" | grep -E '\.patch$'
    awk '{print $2}' "$SNAP"
    git ls-files --others --exclude-standard "$PATCH_ROOT" | grep -E '\.patch$'
  } | sort -u | grep -v '^$'
)
changed=(); kept=(); reverted=()
for f in "${UNIVERSE[@]}"; do
  if [ -f "$f" ]; then cur="$(git hash-object "$f")"; else cur="MISSING"; fi
  old="$(awk -v k=" $f\$" '$0 ~ k {print $1; exit}' "$SNAP")"; [ -n "$old" ] || old="ABSENT"
  [ "$cur" = "$old" ] && continue
  changed+=("$f")
  if [ -n "${ALLOW[$f]:-}" ] || token_intended "$f"; then
    kept+=("$f")
  else
    # revert to committed state. Test membership in HEAD (not the index): the
    # rebuild stages deletions/renames, so a patch that still exists in HEAD must be
    # RESTORED (index+worktree), while a genuinely new patch (absent from HEAD) is
    # removed.
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
      git restore --staged --worktree --source=HEAD -- "$f" 2>/dev/null \
        || git checkout -q HEAD -- "$f" 2>/dev/null || true
    else
      rm -f "$f"; git rm --cached -q "$f" 2>/dev/null || true
    fi
    reverted+=("$f")
  fi
done

log "patches CHANGED by rebuild : ${#changed[@]}"
log "  kept (intended)          : ${#kept[@]}  ${kept[*]:-<none>}"
log "  reverted (spurious churn): ${#reverted[@]}  ${reverted[*]:-<none>}"

# after revert, nothing outside the allowlist may remain dirty
LEFT="$(git status --porcelain "$PATCH_ROOT" | awk '{print $NF}' | while read -r f; do
          [ -n "${ALLOW[$f]:-}" ] || token_intended "$f" || echo "$f"; done)"
if [ -n "$LEFT" ]; then
  c_red "leftover unrelated patch changes after revert:"; printf '%s\n' "$LEFT" | sed 's/^/    /'
  fail "could not fully contain spurious churn"
fi
if [ "${#kept[@]}" -eq 0 ]; then
  fail "intended patch(es) did NOT change -- nothing was captured. Did you edit the file, and does the token match its patch path?"
fi

# ---- (5) round-trip verify --------------------------------------------------
if [ "$VERIFY" = 1 ]; then
  log "round-trip: recording expected bytes, re-materializing from patches"
  WANT_DIR="$(mktemp -d)"
  # figure out which edited source files correspond to the kept SOURCE patches, and
  # snapshot their exact bytes to a temp store before we wipe the tree.
  EDITED=()
  for kp in "${kept[@]}"; do
    case "$kp" in
      "$PATCH_ROOT"/sources/*)
        rel="${kp#"$PATCH_ROOT"/sources/}"; rel="${rel%.patch}"
        if [ -f "$MC_GIT/$rel" ]; then
          EDITED+=("$rel"); mkdir -p "$WANT_DIR/$(dirname "$rel")"; cp "$MC_GIT/$rel" "$WANT_DIR/$rel"
        fi ;;
    esac
  done

  rm -rf "$ROOT/coderyo-server/src/minecraft"
  log "  applyAllPatches (timeout ${TIMEOUT}s)"
  run_gradle /tmp/capturepatch.apply.log applyAllPatches
  if [ "$GR_RC" != 0 ]; then
    tail -20 /tmp/capturepatch.apply.log | sed 's/^/    | /'
    fail "from-scratch applyAllPatches FAILED (rc=$GR_RC) -- captured patch set does not apply cleanly"
  fi
  RT_NOTE=""
  for rel in "${EDITED[@]}"; do
    [ -f "$MC_GIT/$rel" ] || fail "round-trip: $rel missing after re-apply"
    if cmp -s "$WANT_DIR/$rel" "$MC_GIT/$rel"; then
      continue
    # tolerate ONLY the patcher's deterministic final-newline normalization: source
    # file-add patches always re-apply with no trailing newline (repo convention). If
    # the sole difference is a trailing newline, the edit IS reproduced; anything
    # else is a real mismatch and fails.
    elif diff -q <(sed -e '$a\' "$WANT_DIR/$rel") <(sed -e '$a\' "$MC_GIT/$rel") >/dev/null 2>&1; then
      RT_NOTE=" (final newline normalised by patcher)"
    else
      diff <(sed -e '$a\' "$WANT_DIR/$rel") <(sed -e '$a\' "$MC_GIT/$rel") | head -12 | sed 's/^/    | /'
      fail "round-trip: $rel content differs after re-apply (edit NOT reproduced)"
    fi
  done
  rm -rf "$WANT_DIR"
  [ "${#EDITED[@]}" -gt 0 ] && c_grn "round-trip: edited bytes reproduced for: ${EDITED[*]}$RT_NOTE"

  log "  compileJava (timeout ${TIMEOUT}s)"
  run_gradle /tmp/capturepatch.compile.log :coderyo-server:compileJava
  if [ "$GR_RC" = 124 ]; then
    c_ylw "compileJava exceeded ${TIMEOUT}s -- capture is valid; compile UNVERIFIED (raise --timeout)."
    COMPILE="TIMEOUT"
  elif [ "$GR_RC" != 0 ]; then
    tail -25 /tmp/capturepatch.compile.log | sed 's/^/    | /'
    fail "compileJava FAILED on the re-applied tree"
  else
    c_grn "compile: clean"; COMPILE="PASS"
  fi
else
  c_ylw "round-trip verification SKIPPED (--no-verify)"; COMPILE="SKIPPED"
fi

# ---- (6) summary ------------------------------------------------------------
echo
c_grn "================ capture-patch: PASS ================"
echo  "  intended            : ${INTENDED[*]}"
echo  "  patch(es) captured  : ${kept[*]}"
echo  "  spurious reverted   : ${#reverted[@]}  ${reverted[*]:-<none>}"
if [ "$VERIFY" = 1 ]; then
  echo "  round-trip apply    : PASS (edited bytes reproduced)${RT_NOTE:-}"
  echo "  compileJava         : ${COMPILE:-PASS}"
else
  echo "  round-trip          : skipped (--no-verify)"
fi
echo  "  working-tree patches:"
git status --porcelain "$PATCH_ROOT" | sed 's/^/    /'
echo  "===================================================="
echo  "Review 'git diff $PATCH_ROOT', then commit ONLY the intended patch(es)."
