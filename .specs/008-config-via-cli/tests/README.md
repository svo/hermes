# 008 checks

Verification for [SPEC.md](../SPEC.md) and [PLAN.md](../PLAN.md). No image, no credentials, no
Anthropic key: the real `entrypoint.sh` runs against stub `openclaw` and `gog` binaries.

```bash
.specs/008-config-via-cli/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `setter-test` | Criteria 1, 2, 3 and 5 — the config goes through a validating setter, a bad key fails closed and is redacted, and a sibling survives a restart. |
| `approvals-test` | Criterion 4 — the retired `exec-approvals.json` is not written, and one that already exists is migrated rather than deleted. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `gateway health`, `config patch`, `config set`, `config get`, `config validate`, `doctor`, `automations list`. |
| `stub-gog` | Fake `gog`. Records and succeeds. |

Thirty-two cases: 19 in `setter-test`, 13 in `approvals-test`. Nothing skips.

## The probe came first

`SPEC.md` opens with a `verify-locally` check and the instruction to run it **before anything
else in this spec**, because its answer decides whether 008 is a tidy-up or a live problem. It
was run against `openclaw@2026.9.2` — the version `roles/openclaw/defaults/main.yml` pins, so the
schema consulted is the one the container loads. `PLAN.md` § The probe, first records it in full.

Two of the five findings changed verdict:

- **D4 is falsified.** `tools.exec.security` is in the schema — a string with enum
  `deny|allowlist|full`. The finding said it was absent. It stays, and it is now the only place
  the exec policy is written.
- **D3 is confirmed and worse than stated.** The spec guessed the container's
  `exec-approvals.json` "may be doing nothing". `openclaw exec-policy show`, run against the
  exact heredoc the entrypoint used to write, answers `Legacy exec approvals exist at
  /root/.openclaw/exec-approvals.json. Run openclaw doctor --fix before using exec approvals.`
  The container was blocking its own exec approvals with the file it wrote to configure them.

D5 was confirmed and had already been fixed by `78ba48e`. D2 and D6 stand.

## Why this suite is not a `bin/test` check

It is not wired into the gate, and that follows the precedent rather than overlooking it: 002's,
003's, 004's and 007's suites are entrypoint suites too, and none of them is a `bin/test` check
either. Only `bin/hermes-check-test` (005 and 001), 006's `config-schema-check` and 006's own
`run` are.

The specific cost is 006's. Its cases test the gate by building a disposable copy of the whole
repository and running `bin/test` over it, dozens of times, and `red-baseline-test` asserts that
exactly one check goes red in a damaged tree. A new way to go red inside that assertion is not a
change to make casually as part of another spec.

What the gate does still do here is lint these files: discovery finds scripts by shebang rather
than by extension, so `run`, `harness.sh`, both stubs, both suites and `mutation-check` go
through `bash -n` and `shellcheck -x -P SCRIPTDIR -s bash` on every CI run.

## What 006's gate covers that this suite does not

`config-schema-check` runs the real `entrypoint.sh` against stubs and then hands the file it
produced to a **real** `openclaw config validate`. That is the check that decides whether the
payload is legal, and it is why neither stub here validates anything: a stub with a schema
opinion would be a third transcription to keep in step with upstream, and a gate marking its own
homework.

That check was run with the real validator on PATH while this change was made — all ten cases
pass, zero skips, including the red half that asserts an unrecognised key really is rejected.
Two of its expectations moved, and both are recorded in the file itself:

- `agents.defaults.models` now merges rather than being replaced, so the entry onboarding seeded
  survives. Its comment used to say the opposite.
- The emptiness sweep skips leaves that are byte-identical to the seed. The entrypoint patches
  rather than rewrites now, so the file it leaves behind also holds keys it never touched, and
  blaming it for an upstream `{}` would be blaming it for not deleting something.

## What the stub does that a convenient stub would not

**`config patch` performs the real merge.** Objects merge recursively, arrays and scalars
replace, `null` deletes — upstream's documented contract, restated. Getting that right is the
whole of what these cases are about, because the merge is what 008 changed. The entrypoint emits
strict JSON, the JSON5 subset the real command accepts, so `JSON.parse` is enough and no JSON5
parser is needed.

**It is strict about flags** — and so, now, is every other `stub-openclaw` in this repository.
`config patch` accepts `--stdin` and nothing else; `config set` accepts only
`--expect-current-absent`. This is load-bearing rather than tidy, and `mutation-check` proved it:
against a permissive stub, two real regressions produced a completely green run. `--dry-run`
writes nothing at all, and `--replace-path agents.defaults.models` restores the whole-object
clobber this spec exists to remove. Both sailed past, because the merge the stub performed was
its own rather than the one it was asked for.

008's stub was strict from the start; the other five were not, which meant those regressions
would still have passed 006's `config-schema-check` — the only one of these that `bin/test`
runs. An adversarial review of this change caught that, and all six are strict now. With
`--replace-path` injected, 006's gate goes from green to three failures.

**It records the document it was handed.** `OPENCLAW_STUB_PATCH_STDIN` keeps the payload, so a
case can assert on what the entrypoint *sent* rather than only on the file that came out. The two
are different claims: a payload that omitted a key would still leave a correct file on a
container that already had that key, and a `null` deletion and an absent key look identical once
the merge has run.

**`doctor` models four outcomes, because the real one has them.** It retires the legacy file and
succeeds by default. `OPENCLAW_STUB_DOCTOR_FAILS=yes` drives the plain failure — which must warn
and carry on, not refuse to start. The other two are the reason the entrypoint does not read
doctor's exit code at all, and both were found by probing the real command:
`OPENCLAW_STUB_DOCTOR_KEEPS_FILE=yes` exits **zero** while deliberately retaining the file, which
is what happens when SQLite already holds approvals the legacy document conflicts with; and
`OPENCLAW_STUB_DOCTOR_NOISY_EXIT=yes` exits **one** after migrating fine, because
`doctor --fix` is a maintenance pass over everything and fails on unrelated things. Reading the
exit code reports a migration that did not happen in the first case and warns about one that did
in the second. The block asks whether the file is gone. `OPENCLAW_STUB_DOCTOR_ECHO` makes doctor
quote a credential back, which is why its output is redacted like everything else here.

## Mutations

```bash
.specs/008-config-via-cli/tests/mutation-check
```

Twenty-six mutations, one behaviour each, all against a copy of `entrypoint.sh`. Every one is
caught. It is not part of `run` because it re-runs the suites up to twenty-six times.

Each mutation asserts its anchor occurs exactly once in the file, and that the mutant still
parses as bash, before it is applied; a bad anchor is reported as a bad anchor rather than as a
caught or uncaught mutation.

Five are worth knowing about, because each one found a hole rather than confirming a patch:

- **`the model map is replaced rather than merged`** and **`the write is only ever a dry run`**
  both survived the first run. They are the reason the stub is strict about flags. Both are real
  regressions an author could plausibly introduce, and both were invisible.
- **`the heartbeat loses its fence instruction`** matched twice: 003's briefing prompt near the
  bottom of the file carries the same sentence, so the anchor was lengthened to the clause that
  ends the heartbeat's own prompt. Mutating the other one would have been testing 003's cases
  with 008's.
- **`a rejected payload does not stop the start`** matched twice as well — `Compare the key it
  names against` is printed by the phase 3 gate too. The anchor starts one line higher, on
  `Nothing was written`, which belongs to phase 2 alone.
- **`the exec policy is written on every start`** and **`the retired loopDetection thresholds are
  left on the volume`** are the two regressions an adversarial review caught in the first draft of
  this change, and both are the spec's own failure mode reintroduced by the spec. Writing
  `tools.exec.security` in the unconditional patch reverts an operator's tightening on every
  restart — 004's finding B6, at a new address. And a recursive merge stops clearing the stale
  keys a whole-object assignment used to take with it, so a volume from before `78ba48e` would
  keep three `loopDetection` thresholds the schema rejects and never start again. `cron.timezone`,
  `cron.jobs` and `agents.defaults.maxTokens` are the same shape and have their own mutations.
- **`the migration verdict is taken from the exit code`** is the shape the approvals block was
  first written in, and it is wrong in both directions. Probing the real `doctor --fix` turned up
  a run that exited **zero** while deliberately keeping the legacy file — `Preserved canonical
  SQLite exec approvals and retained conflicting legacy JSON`, which happens when SQLite already
  holds approvals the document conflicts with — and a run that exited **one** because an
  unrelated plugin's tool schema would not load, after the approvals had migrated fine. The block
  asks whether the file is gone instead, and the two cases that pin it were written because of
  what the probe did, not because of what it was supposed to do.

## What still needs a container

- **An operator's tuned setting surviving a real restart.** The merge is asserted here against a
  stub that implements upstream's documented contract. That the *real* `openclaw config patch`
  behaves that way was confirmed by the probe — `tools.exec.timeoutSeconds` and `grantExpiryDays`
  survived a re-patch of `security` — but not by anything that runs on its own.
- **`openclaw exec-policy show` reporting `security=full` from `tools.exec.security`.** Confirmed
  by the probe, with the legacy file removed. Nothing here can ask SQLite what it holds.
- **The migration importing a policy rather than discarding it.** `doctor --fix` was run against
  the exact stub heredoc and reported `Imported legacy exec approvals into shared SQLite state`,
  after which `exec-policy show` said `Approvals State: stored`. What the suite asserts is the
  route — that the file was handed to the importer rather than unlinked — because SQLite is
  upstream's and this suite has no window into it.
- **The breadth of `doctor --fix`.** In the probe it also altered
  `browser.extensionRelay.allowLegacyAuth` and rebuilt the agent roster. The guard keeps it to at
  most one run per volume, and `should_not_run_the_migration_when_no_legacy_file_exists` pins
  that, but what it does on a real config is not something a stub can model.
