# coderyoMC e2e test harness

A reusable, mock-free end-to-end test runner for coderyoMC (issue #5). It boots a
**real** `createPaperclipJar` server headless, drives it with scripted console
commands, captures the full log, and runs grep-based assertions against it. This
is the production-path runner mandated by `design-spec.md` §8 (測試策略): **no unit
tests, no mocks — every test starts a real server and asserts on observable
behaviour** (log lines + world-state side effects).

## Files

| File | Purpose |
|---|---|
| `e2e-harness.sh` | The generic runner. Boots a jar, scripts stdin commands, asserts on the log, stops, verifies clean shutdown. |
| `selftest.sh` | Proves the harness e2e against the current paperclip jar on port 15565 (boot → `/forceload add 0 0` → assert `Done (` → stop). |

Both are POSIX bash, written to run on Windows 11 / Git Bash with Temurin JDK 25.

## Port convention (IMPORTANT)

- Test servers bind **`15565 + N`**, selected with `--port-offset N`.
  - offset `0` → **15565** (primary / region tests)
  - offset `1` → 15566, offset `2` → 15567, … (parallel agents)
- **Never 25565.** That is the developer's live server. The harness *refuses* to
  bind 25565 and exits with code 4 if you try.
- Headless tests run with `online-mode=false` (the harness writes this for you).

## Quick start

Build a paperclip jar once (multi-GB first time; paperweight cache is shared):

```bash
./gradlew applyAllPatches
./gradlew createPaperclipJar      # -> coderyo-server/build/libs/coderyo-paperclip-*.jar
```

Run the self-test (auto-discovers the newest paperclip jar):

```bash
test-harness/selftest.sh
# or with an explicit jar:
test-harness/selftest.sh coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar
```

## General usage

```bash
test-harness/e2e-harness.sh \
  --jar coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar \
  --port-offset 0 \
  --cmd "forceload add 0 0" \
  --cmd "tps" \
  --assert-present 'Done \(' \
  --assert-present 'coderyo-region-worker' \
  --assert-absent  'single-writer .* VIOLATION' \
  --assert-absent  'Exception'
```

What it does, in order:

1. Computes `port = 15565 + offset` (refuses 25565).
2. Writes `run/` `server.properties` (`server-port`, `online-mode=false`) +
   `eula.txt` (`eula=true`) into the run dir.
3. Boots the jar headless: `java … -jar <jar> --nogui --port <p>`.
4. Waits up to `--boot-timeout` (default 300s) for `Done (`.
5. Pipes each `--cmd` / `--cmds-file` line to the server stdin, with a
   `--cmd-delay` (default 2s) pause between them.
6. Sends `stop`, waits up to `--stop-timeout` (default 120s) for the process to
   exit, and checks for a clean-shutdown marker.
7. Runs all `--assert-present` / `--assert-absent` patterns against the captured
   log and prints a PASS/FAIL line per assertion.
8. Exits non-zero if any assertion fails or shutdown hangs.

### Options

Run `test-harness/e2e-harness.sh --help` for the full list. Highlights:

- `--jar PATH` (required) — the paperclip jar.
- `--port-offset N` — port = 15565 + N. Default 0.
- `--cmd "text"` — a console command to send (repeatable).
- `--cmds-file FILE` — one command per line (`#` comments ignored).
- `--assert-present PAT` / `--assert-absent PAT` — `grep -E` patterns (repeatable).
- `--run-dir DIR`, `--keep-run`, `--log FILE`, `--heap MB`, `--extra-jvm "…"`,
  `--java PATH`, `--boot-timeout`, `--stop-timeout`, `--cmd-delay`.

### Exit codes

| code | meaning |
|---|---|
| 0 | all assertions passed, clean shutdown |
| 1 | an assertion failed |
| 2 | server never printed `Done (` within `--boot-timeout` |
| 3 | server did not shut down within `--stop-timeout` |
| 4 | usage / config error (incl. attempt to bind 25565) |

## Use in region / GPU / compat e2e tests

The assertion patterns are plain `grep -E`, so the markers the other phases
already grep for drop straight in:

- **Region (P1):** `--assert-present 'coderyo-region-worker'`,
  `--assert-present 'single-writer'`, `--assert-absent 'thread-check .* VIOLATION'`.
- **GPU (P2):** `--assert-present 'RESULT_.*PARITY'`, `--assert-present 'OpenCL'`,
  `--assert-absent 'parity fail'`.
- **Compat (P3):** `--assert-present 'demoteToLegacy'`,
  `--assert-absent 'silent'`, `--assert-absent 'Exception'`.

Drive scenarios by scripting console commands (`--cmd`, `--cmds-file`):
`forceload add`, `tp`, `summon`, `gamerule`, `save-all`, etc. — then assert on
the resulting log lines / `RESULT_*` markers your test code emits.

## CI / gh-friendly wrapper

No Gradle build-file changes are bundled (to stay conflict-free with the
server-side patch streams). To wire into CI, call the script after `assemble`:

```yaml
- run: ./gradlew applyAllPatches --stacktrace
- run: ./gradlew createPaperclipJar --stacktrace
- run: bash test-harness/selftest.sh
```

Because `selftest.sh` (and `e2e-harness.sh`) return a non-zero exit code on any
failure, they gate the job directly — no extra glue needed.
