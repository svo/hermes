# Plan: Configuration through the CLI rather than by hand

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## The probe, first

`SPEC.md` opens with a *verify-locally* check and the instruction to **run that before anything
else**, because its answer decides whether this spec is a tidy-up or a live problem. It was run
against `openclaw@2026.9.2` — the version `roles/openclaw/defaults/main.yml` pins, so the schema
consulted is the one the container actually loads.

**The answer is: mostly a tidy-up, with one live problem that is not the one the spec expected.**

| ID | Spec's claim | Probe verdict |
|---|---|---|
| D2 | ~15 keys hand-written into strict schemas | confirmed — the class is real |
| D3 | `exec-approvals.json` is retired; the container's `security: full` may be doing nothing | **confirmed, and worse** — it is not doing nothing, it is *blocking* |
| D4 | `tools.exec.security` is absent from the schema | **falsified** — it is present |
| D5 | the three `loopDetection` thresholds are absent | confirmed, and already fixed by `78ba48e` |
| D6 | whole-object writes clobber operator-set siblings | confirmed, and live on a key nobody had noticed |

### D4 is falsified — the key is real

```
tools.exec: additionalProperties: false
keys: host, mode, security, ask, node, pathPrepend, safeBins, strictInlineEval,
      commandHighlighting, grantExpiryDays, safeBinTrustedDirs, safeBinProfiles, reviewer,
      backgroundMs, approvalRunningNoticeMs, timeoutSeconds, cleanupMs, notifyOnExit,
      notifyOnExitEmptySuccess, applyPatch
tools.exec.security = {"type":"string","enum":["deny","allowlist","full"],"title":"Exec Security"}
```

`tools.exec.security = 'full'` is valid. 004's gate was never going to refuse a container over
it. Acceptance criterion 5 is met by confirming it, not by removing it.

### D5 is confirmed, and was already fixed

`tools.loopDetection` accepts exactly `enabled`, with `additionalProperties: false`. The
entrypoint already writes only `enabled`; `78ba48e` removed the three thresholds. Nothing to do
here beyond recording that the probe agrees with the fix.

### D3 is the live problem

The heredoc `entrypoint.sh` writes, then `openclaw exec-policy show`:

```
Legacy exec approvals exist at /root/.openclaw/exec-approvals.json.
Run `openclaw doctor --fix` before using exec approvals.
```

The spec guessed the file's `security: full` "may be doing nothing". It is doing something
worse: approvals now live in `~/.openclaw/state/openclaw.sqlite#exec_approvals_config`, and a
leftover file with a **non-empty** `defaults` is a legacy document that upstream refuses to read
past. Doctor auto-retires only *policy-free* stubs, and this one has a policy. So every fresh
container ships a file that puts its own exec approvals into a blocked state.

Removing the file leaves exactly the intent that was wanted:

```
Approvals        ~/.openclaw/state/openclaw.sqlite#exec_approvals_config
Approvals State  defaults (no stored overrides)
Effective        security=full        <- sourced from tools.exec.security
```

`tools.exec.security` — the key D4 said was absent — is what carries the policy once the legacy
file is out of the way. The two findings answer each other.

One asymmetry to keep straight, because the probe produced both states. A container that never
had the file ends at `Approvals State: defaults (no stored overrides)`, sourcing the policy from
that key. A container that is *migrated* ends at `Approvals State: stored`, because the import
puts the old file's policy into SQLite, where it wins over the key. That is the intended outcome
of migrating rather than deleting — it is how an operator's tightening survives — but it does
mean "the policy lives at `tools.exec.security`" is the fresh-container story, and the README
says which command distinguishes them.

### The Open Questions are both answered, and the answer is one command

`openclaw config` publishes `patch`:

> Patch config from a JSON5 object in one validated write. Objects merge recursively,
> arrays/scalars replace, and null deletes a path.

- **Open Question 1 — does it accept every shape this entrypoint needs?** Yes, all of them. The
  multi-line heartbeat prompt, containing both double and single quotes, round-trips
  **byte-identical**. `tools.deny` and `commands.ownerAllowFrom` are arrays and replace cleanly.
  `null` deletes, which retires the four `delete config.x` lines. No key has to stay behind in a
  `node -e` block; the class dissolves completely rather than mostly.
- **Open Question 2 — is the config writable while the gateway is not running?** Yes.
  `Applied 21 config update(s).` with nothing running. The sequence stays where it is, in phase
  2, and a failure keeps meaning what it means today.

### Two things the spec did not know

**`patch` already satisfies acceptance criterion 2.** It fails closed and names the key:

```
Config validation failed: tools.loopDetection: Unrecognized key: "warningThreshold"
```

exit 1, and the config on disk is untouched. That criterion is met by the primitive itself
rather than by anything this repository has to write.

**`patch` output can quote the payload back.** An over-long key came back elided, not withheld:

```
Config validation failed: tools.loopDetection: Unrecognized key: "sk-ant…NAME"
```

The payload carries five credentials. Eliding the middle of a long string is a mitigation, not a
guarantee — a short token survives it intact — so phase 2's patch output needs the same
`redact_secrets` treatment phase 3 already gives the validator. This is the same reasoning 007
recorded when it added a fifth credential to that filter, arriving one phase earlier.

## Implementation Strategy

**One track, three commits.** They are separable, they fail differently, and the second is the
only one that changes what an operator's container does at runtime.

**Commit 1 — the setter.** Convert the first `node -e` block from a read-modify-write into a
*payload builder* whose stdout is piped into `openclaw config patch --stdin`. The JavaScript
stays: it reads a dozen environment variables, derives `ownerAllowFrom`, and carries comments
that are the record of four separate bugs. What changes is its last line — `writeFileSync`
becomes `process.stdout.write`, and the file is opened by the validator instead of by us. Every
key is then checked against the live schema at the moment it is written, which is acceptance
criterion 1, and the recursive merge is criterion 3.

**Commit 2 — exec approvals.** Stop writing `exec-approvals.json`; migrate the volumes that
already carry one. This is the live finding and the only behaviour change an operator will
notice.

**Commit 3 — the stubs and the gate.** Five `stub-openclaw` files learn `config patch`, and
006's `config-schema-check` expected table is updated for the one place the merge changes the
result. This has to land *with* commit 1, not after it: the stubs are strict, and an entrypoint
calling a subcommand they do not model exits 64.

Sequencing note: commits 1 and 3 are one landing. Commit 2 was planned to stand alone.

**It did not, and the reason is worth recording.** The three landed as one commit, because the
work turned out to be one change rather than three once the probe was in: the exec policy moving
to `tools.exec.security` is *why* `exec-approvals.json` stops being written, and the stale-key
nulls exist *because* the setter merges. Splitting them would have meant authoring an
intermediate entrypoint that never ran — one that patches through the setter while still writing
the retired file, and still reverts an operator's exec policy on every restart. A commit whose
state never existed is a worse artefact than a large one that did.

The separability the plan wanted is still real at the level that matters: each behaviour has its
own cases and its own mutations, so a revert of any one piece is a red suite rather than a
silence.

## Layer Changes

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)

Owned region: the first `node -e` block, plus two sanctioned crossings into 004 recorded below.

- The block becomes `build_openclaw_config_payload | openclaw config patch --stdin`, captured so
  that a failure can be redacted before it reaches `docker logs`.
- `delete config.tools.allow`, `delete config.env.ANTHROPIC_API_KEY`, `delete config.agent` and
  `delete config.heartbeat` become `null` values in the payload.
- The read-modify-write disappears: no `readFileSync`, no `writeFileSync`, no parse of a file
  another block may have written since.
- `tools.exec.security` **stays**, now with the probe recorded beside it — but it is set by a
  separate `config set --expect-current-absent` rather than by the patch, so that a restart
  cannot revert an operator's tightening. That is 004's finding B6, which the old
  `exec-approvals.json` guard held and which moving the policy would otherwise have broken.
- The `exec-approvals.json` heredoc is replaced by a migration that runs only when a legacy file
  is present.

### Documentation

- `README.md` § *The configuration is validated against the schema* — the "roughly fifteen keys
  are written into strict schemas by hand" framing goes, per SPEC § Structural Impact. The phase
  3 gate is no longer the only check; it becomes the backstop behind a validating write.
- `README.md` § *Exec approvals are yours after the first start* — rewritten. The advice it
  gives (`rm` the file and restart) is advice to recreate the blocked state.
- `README.md` § *Credentials on disk are mode 0600* — the approvals file is normally absent now,
  so the wording changes even though the step still names three paths. It keeps naming
  `exec-approvals.json` behind its `[ -f ]` guard on purpose: a migration that fails leaves the
  file, and until it is retired it still holds an exec policy on a bind mount the host can read.

### Image & CI

- `.specs/006-lint-and-test-gate/tests/config-schema-check` — the `agents.defaults.models`
  expectation, and the comment above it, invert. See § The one behavioural change below.
- `.specs/{002,003,004,006,007}/tests/stub-openclaw` — each learns `config patch`.

## Configuration Contract

| In | Out |
|---|---|
| the same dozen `HERMES_*` / `ANTHROPIC_API_KEY` variables as today | the same key paths, written through a validating setter |
| a legacy `~/.openclaw/exec-approvals.json` | imported into `state/openclaw.sqlite#exec_approvals_config`, then retired |
| — | `tools.exec.security` carries the exec policy, alone — defaulted to `full` on the one start that finds none, and never rewritten after that |

No new environment variable. This spec changes how keys are written, not which ones.

## The one behavioural change

`agents.defaults.models` is an upstream-seeded map. Today's whole-object assignment deletes
every entry the container did not write; under a recursive merge they survive.

That is not incidental. In the probe the real config carried `anthropic/claude-sonnet-5` and
`anthropic/claude-sonnet-4-6`, seeded by upstream's own `modelPolicyAllowlist` migration —
entries in a *model policy allowlist*, which today's entrypoint silently deletes on every start.
Upstream protects this path deliberately: `openclaw config set` requires an explicit `--replace`
for "protected map/list paths such as `agents.defaults.models`". `config patch` has
`--replace-path`, which would preserve today's behaviour exactly, and it is **not** used, because
an operator adding a model's parameters beside the container's is precisely the case acceptance
criterion 3 names.

006's `config-schema-check` asserts the current wipe, with a comment explaining that the seeded
model "is shown to be gone rather than left beside the one the container actually uses". That
expectation and that comment both invert. 006's check was written to be updated this way —
"Extending the entrypoint means extending the table, which is the point."

## Region ownership, and two crossings into 004

`.specs/README.md` § Shared-file ownership gets a row for 008. Two of the three changes are
inside regions the table assigns to **004**, and both are declared here rather than discovered
later, following the precedent 007 set.

**Crossing 1 — the `exec-approvals.json` guard.** The table gives this to 004, which wrote the
`[ ! -f ]` guard to stop a restart reverting an operator's tightened `defaults.security`. 008 removes the write
entirely, which is what SPEC acceptance criterion 4 asks for by name. 004's reason for the guard
is honoured rather than discarded: `doctor --fix` *imports* the operator's policy into SQLite
instead of deleting it, so a tightened `defaults.security` survives the migration.

**Crossing 2 — hoisting `redact_secrets` above phase 2.** The function is defined immediately
above 004's phase 3 gate. Phase 2 now has output that can quote payload content, and the payload
holds five credentials, so the filter has to exist before phase 2 runs. The definition moves; not
one line of its body or of the phase 3 gate changes, and bash resolves function names at call
time, so nothing else is affected. The rule 007 stated applies unchanged: a spec that puts a
credential where something reads it aloud owns the redaction of that credential.

004's mutation anchors are untouched by both crossings. Its **suite is not**: 008 inverts
behaviour that four of 004's cases pin, so `state-test` (three approvals cases), `config-test`
(one), `gate-test` (one), `harness.sh` (a `doctor_ran` helper) and its stub (two tables) all
change with it. Two of those were already failing on `main` before 008 began — `config-test` and
`gate-test` still asserted the three `loopDetection` thresholds `78ba48e` removed — and are fixed
here. 007's `permissions-test` changes for the same reason: the file whose mode it asserted is no
longer written.

## Task List

1. [ ] **run the probes** (SPEC § Source Findings, D4/D5) — done; verdicts recorded above and in
       the commit message. D4 falsified, D5 already fixed, D3 worse than stated.
2. [ ] runtime-config: convert the first `node -e` block to a payload builder piped into
       `openclaw config patch --stdin`.
3. [ ] runtime-config: replace the four `delete` statements with `null` values, and add nulls for
       every key a whole-object assignment used to clear —
       `tools.loopDetection.{warningThreshold,criticalThreshold,globalCircuitBreakerThreshold}`,
       `cron.{timezone,jobs}` and `agents.defaults.maxTokens`.
4. [ ] runtime-config: set `tools.exec.security` with `config set --expect-current-absent`,
       outside the patch, so a restart cannot revert an operator's tightening (004's B6).
5. [ ] runtime-config: hoist `redact_secrets` above phase 2 and route the patch failure through
       it (crossing 2).
6. [ ] runtime-config: stop writing `exec-approvals.json`; run `openclaw doctor --fix
       --non-interactive` only when a legacy file is present, judge the outcome by whether the
       file is gone rather than by its exit code, and redact its output (crossing 1).
7. [ ] tests: teach `config patch` and `config set --expect-current-absent` to all six
       `stub-openclaw` files — strict JSON on stdin, recursive merge, `null` deletes, and a
       write that refuses when the path is already there.
8. [ ] tests: update 006's `config-schema-check` for the `agents.defaults.models` merge, and
       invert its comment.
9. [ ] tests: a new `008/tests` suite — the setter is used, the keys arrive, siblings survive, an
       unrecognised key fails closed and is redacted, the approvals file is gone and a legacy one
       is migrated.
10. [ ] tests: `mutation-check`, in this repository's shape — every case shown failing against a
       deliberately broken entrypoint.
11. [ ] docs: `README.md` — the three sections named above.
12. [ ] docs: `.specs/README.md` — 008's ownership row, its two crossings, and the removal of the
        "008 and 009 are not planned yet" line.

## Testing Strategy

No test framework exists; verification is config-level, as it is for every spec here.

- **Probe-first** (task 1). The severity of three findings depended on the answer and two of the
  five verdicts changed. The commit message records them.
- **The setter is actually used.** Assert `INVOCATION [config patch]` in the argv log, not merely
  that the config came out right — a `node -e` block that still wrote the file directly would
  satisfy every value assertion while dissolving nothing.
- **Sibling survival** — seed `tools.exec.timeoutSeconds` and a second entry in
  `agents.defaults.models`, restart, assert both are still there. This is the criterion the old
  code fails, so it is the case that must be shown red first.
- **Fail-closed** — an unrecognised key makes the start exit non-zero, name the key, and leave
  the config as it was. Driven through the stub rather than the real schema, because the suite
  must not need a network or an image.
- **Redaction** — make the patch fail with a message quoting a credential and assert no
  credential reaches either stream. This is the case that justifies crossing 2, so it is the case
  that must exist.
- **Approvals** — a fresh start writes no `exec-approvals.json`; a start on a volume that has one
  runs `doctor --fix` exactly once and the file is gone afterwards; a start on a volume without
  one never calls doctor at all.
- **The real schema** — 006's `config-schema-check` already runs the real validator over the
  generated config, and it keeps doing so. That is the check that would catch a payload this
  suite's stub is too kind about.
- Naming: `should_<behaviour>_when_<condition>`.

## Operability Plan

- One line per start, unchanged in shape: `config: validated`. The patch itself is quiet on
  success — a per-key log would put a credential-bearing payload in `docker logs`.
- A rejected key names itself at the write, one phase earlier than before, and says which key.
- The migration says so once, and only when it does something.
- Operator checks: `openclaw config get tools.exec.security`, `openclaw exec-policy show` (which
  now reports a policy rather than a legacy-file error), `openclaw config validate --json`.

## Risks and Mitigations

- **Risk:** the five stubs are strict — an entrypoint calling `config patch` against a stub that
  does not model it exits 64 and takes 002, 003, 004, 006 and 007's suites down with it.
  → **Mitigation:** task 6 lands in the same commit as task 2. The payload is emitted as strict
  JSON, a subset of the JSON5 the real CLI takes, so a stub can parse it with `JSON.parse`
  instead of needing a JSON5 parser. All five suites are run before and after.
- **Risk:** the stub's merge and the real `patch`'s merge disagree, and the suite goes green over
  behaviour the container does not have. → **Mitigation:** 006's `config-schema-check` runs the
  **real** validator over the generated config, and the builder image carries the pinned CLI. The
  stub decides what the file looks like; upstream decides whether it is legal.
- **Risk:** a stub that ignores an unrecognised flag models a merge nobody asked for. Two real
  regressions — `--dry-run`, which writes nothing, and `--replace-path agents.defaults.models`,
  which restores the clobber — produced entirely green runs against a permissive stub.
  → **Mitigation:** every `stub-openclaw` in the repository now rejects a flag it does not model,
  which is the discipline 006's own stub header already stated and did not yet apply to this
  subcommand. Verified by injecting `--replace-path` and watching 006's gate go from green to
  three failures.
- **Risk:** `doctor --fix` is broad. In the probe it also touched
  `browser.extensionRelay.allowLegacyAuth` and rebuilt the agent roster. → **Mitigation:** it
  runs **only** when a legacy `exec-approvals.json` is present, so it fires at most once per
  volume and never on a container created after this change. Running it unconditionally on every
  start was considered and rejected for exactly this breadth.
- **Risk:** `doctor --fix`'s exit code does not mean "the approvals migrated". Probing it turned
  up both directions. It exits **zero** while deliberately keeping the legacy file when SQLite
  already holds approvals the document conflicts with — `Preserved canonical SQLite exec
  approvals and retained conflicting legacy JSON` — and it exits **one** after migrating the
  approvals fine, because it is a maintenance pass over everything and an unrelated plugin's tool
  schema failing to load is enough. → **Mitigation:** the block does not read the exit code. It
  asks whether the file is gone, which is the thing actually cared about and is right in both
  cases. The conflict case is the operator's to settle, because only they know which policy they
  meant, so the message says that and gives them the command.
- **Risk:** `doctor --fix` prints a couple of hundred lines of report, having read a config that
  holds five credentials. → **Mitigation:** its output is captured, not streamed; on the one path
  where any of it is printed it goes through `redact_secrets`, tail-limited to twenty lines. Same
  rule as the setter's output and the phase 3 validator's.
- **Risk:** an operator who tightened `defaults.security` in the legacy file loses it.
  → **Mitigation:** this is why the file is migrated rather than deleted. `doctor --fix` imports
  the policy into SQLite; the probe confirms `Approvals State: stored` afterwards. Deleting it
  would reintroduce the exact bug 004's `[ ! -f ]` guard exists to prevent.
- **Risk:** the payload builder writes something to stdout that is not JSON, and the patch
  receives a corrupted document. → **Mitigation:** the builder's only output statement is the
  final `process.stdout.write`; diagnostics go to stderr. A malformed payload fails the patch
  closed, which is the safe direction.
- **Risk:** `pipefail` semantics — a builder that fails mid-pipe is masked by a patch that
  succeeds on a truncated payload. → **Mitigation:** the file already sets `-o pipefail` at line
  2, so either side failing fails the pipeline, and the result is captured in a
  `if ! output="$(...)"` so the status is read rather than assumed.
- **Risk:** the recursive merge keeps a key a previous image wrote and this one no longer wants.
  → **Mitigation:** that is what `null` is for, and the four existing deletions use it. 006's
  `coverage` section reports any key present that no assertion accounts for, so a stale key
  cannot arrive silently.
- **Risk:** `config patch` rewrites `openclaw.json`, so it could re-create it at the process
  umask and reopen the 0644 window 007 closed with a `chmod` straight after onboarding — the
  window matters because everything between there and the permissions step runs under `set -e`,
  and a start that dies in the middle would leave a world-readable credential on the volume.
  → **Checked, and it does the opposite.** Against the pinned CLI the file goes in at 0600 and
  comes out at 0600, and a file left at 0644 by an older image comes out at **0600** — the setter
  tightens rather than loosens. 007's permissions step still runs afterwards and still asserts it.
- **Risk:** removing the legacy file *widens* what the agent may run. While it is there the
  approvals subsystem refuses to report a policy — `openclaw approvals get` answers only with the
  legacy warning — and once it is gone it reports `Defaults security=full`. So if that blocked
  state was holding exec back, this change stops holding it back. → **Deliberate, and stated.**
  `tools.exec.security: full` is unchanged from HEAD; what changes is that the container's
  declared policy is now actually in force rather than sitting behind a file upstream will not
  read. That is the fix, not a side effect. The README says so plainly and tells an operator to
  check the key before upgrading rather than after, because "the setting you already had now
  applies" is still a change in behaviour on the day it lands.
- **Risk:** `doctor --fix` does more than migrate. It is a maintenance pass, and where a
  configured channel's plugin is not bundled it can fetch one — which would put a registry
  install into container start, exactly the build-time-resolution problem 007 pinned everything to
  remove. → **Bounded rather than dismissed:** it runs only while a legacy `exec-approvals.json`
  is present, so it cannot reach a container created after this change and normally runs once on
  an upgrading one. It was not observed installing anything in the probe (no `~/.openclaw/npm`
  was created), but that was a container with no channel plugins configured, so absence of
  evidence is all it is. An operator who would rather not run it at all can retire the file by
  hand before upgrading.
- **Risk:** this is read as "the config is now safe". → **Mitigation:** it is not. The schema
  says a key is *recognised*, never that its value is *right* — `tools.exec.security = 'full'` is
  schema-valid and is also the most permissive setting available. Say so in the README rather
  than letting a validating writer imply more than it checks.
