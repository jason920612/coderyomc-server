# `capture-patch.sh` — safe patch capture (issue #26)

paperweight's patch-rebuild tasks (patcher `2.0.0-beta.21`) are flaky on
Windows/alpha-upstream. When you capture a minecraft-source or feature edit with a
bare `./gradlew rebuildMinecraftSourcePatches` / `rebuildAllServerPatches`, the task
**injects spurious churn into unrelated patches** — this has cost ~15 manual
detect-and-revert cycles. `capture-patch.sh` runs the real rebuild but contains the
damage automatically, so capture is safe and one command.

## The bug it tames (reproduced in this repo)

Every source rebuild re-touches the two hand-authored EOF patches regardless of
what you edited:

```
sources/com/coderyo/compat/Governor.java.patch
sources/com/coderyo/compat/MarshalRouter.java.patch
    @@ -1,0 +_,130 @@   ->   @@ -1,0 +_,131 @@
    +}                                          (drops "\ No newline at end of file")
```

Those two `.patch` files were hand-authored during earlier misfire workarounds with
a no-trailing-newline EOF that codechicken-diffpatch does **not** reproduce verbatim,
so **every** rebuild regenerates them with an off-by-one line count. On Windows the
nested materialized-tree git also inherits `core.autocrlf=true` from the
Git-for-Windows SYSTEM gitconfig (the primary repo's local `false` does not cover
it), adding CRLF churn across ~5000 files; and in the worst case the rebuild has
aborted mid-run and deleted an unrelated patch (the original issue-#26 report).

## What the wrapper does

1. **Prerequisites.** Forces `core.autocrlf=false` on the primary repo **and** the
   nested `coderyo-server/src/minecraft/java` git; folds any uncommitted source edit
   into its file-patches commit (`fixupMinecraftSourcePatches`) so the rebuild's diff
   baseline is clean (the rebuild reads the *commit*, not the worktree).
2. **Snapshots** every tracked `coderyo-server/minecraft-patches/**.patch` (content
   hash).
3. **Runs the real rebuild** (`rebuildMinecraftPatches`) under a hard timeout.
4. **Detects + reverts** every patch that changed / was added / was deleted **other
   than the intended one(s) you named** — restoring the Governor/MarshalRouter EOF
   churn and anything else to its committed state.
5. **Round-trip verifies:** deletes the materialized tree, `applyAllPatches` from
   scratch, asserts the re-applied file reproduces your **exact edited bytes**, then
   `:coderyo-server:compileJava` compiles clean.
6. Prints a **PASS/FAIL** summary.

Anti-hang: every gradle task runs under `--timeout` seconds (default 300); a hung
task is killed, never wedges the wrapper.

## Usage

```bash
# 0. tree materialized once:
./gradlew applyAllPatches

# 1. edit your file in the materialized tree, e.g.
#    coderyo-server/src/minecraft/java/com/coderyo/compat/CompatConfig.java

# 2. capture — name the patch you MEANT to change (substring match on patch path):
test-harness/tools/capture-patch.sh CompatConfig
#    a feature patch by number works too:
test-harness/tools/capture-patch.sh 0017
#    multiple + skip the slow round-trip:
test-harness/tools/capture-patch.sh CompatConfig MarshalRouter --no-verify

# 3. review and commit ONLY the intended patch:
git diff coderyo-server/minecraft-patches
git add coderyo-server/minecraft-patches/sources/com/coderyo/compat/CompatConfig.java.patch
git commit -m "..."
```

Options: `--no-verify` (skip round-trip+compile), `--timeout N` (per-task seconds),
`-h`.

## Guarantees, and what it does *not* fix

* **Guaranteed:** the intended patch is captured, and **every** spurious change to
  any other tracked patch is reverted to its committed state — the working tree is
  left clean except the patch(es) you named. Verified end-to-end: a trivial edit to
  `CompatConfig.java` captured only `CompatConfig.java.patch`; the Governor +
  MarshalRouter EOF churn was auto-reverted; `applyAllPatches` reproduced the exact
  bytes and `compileJava` was clean.
* **Not fixed (upstream, irreducible):** the beta patcher still *emits* the
  Governor/MarshalRouter EOF churn on every run — the wrapper reverts it rather than
  preventing it. Re-canonicalising those two patches to diffpatch's exact EOF format
  would stop the emission, but that is out of scope here.

## Feature edits

For an upstream (`net/minecraft/**`) edit the patch is a numbered `features/**`
patch captured from a **committed** feature commit — commit your edit in the
materialized git first (`git -C coderyo-server/src/minecraft/java commit -am '…'`),
then run `capture-patch.sh <NNNN>`. The wrapper reverts only the patches you did not
name, so unrelated feature-patch renames are contained too.
