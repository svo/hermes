# 004 checks

Verification for [SPEC.md](../SPEC.md). No image, no credentials, no Anthropic key — the
real `entrypoint.sh` runs against a stub `openclaw` on `PATH`, and the cases read the
`openclaw.json` it writes, or the fact that it wrote nothing at all.

```bash
.specs/004-entrypoint-startup-correctness/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `validation-test` | Phase 1 — the permutation matrix, the conditional channel rules, and `HERMES_OWNER`. |
| `state-test` | What a restart must not destroy: the persisted API key, and edited approvals. |
| `config-test` | Phase 2 — what lands in `openclaw.json`, and what no longer does. |
| `gate-test` | Phase 3 — the `openclaw config validate` gate. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `gateway health`, `config get`, `config validate`. |

Sixty-four cases: 27 in `validation-test`, 9 in `state-test`, 16 in `config-test`, 12 in
`gate-test`.

## Why not a container

`PLAN.md` § Testing Strategy specifies container-level verification — `docker run` with a
variable omitted, `sha256sum openclaw.json` either side, `docker exec hermes openclaw config
get`. That needs the image and an Anthropic API key, so it is not something a check can do on
its own.

What these cases assert is the same behaviour by a shorter route. The entrypoint is the thing
under test either way; only `openclaw` is replaced. Each run gets a private `HOME` and an
`env -i` environment carrying just the variables the case wants, so no persisted config or
ambient variable carries between cases. A case that needs to model a config volume surviving a
restart passes the same `HOME` to several runs — which is the only way two of these findings
are visible at all, because the first start is what creates the state the second was
destroying.

## Omitted, not blank

`run_entrypoint --omit VAR` drops a variable from the environment entirely, which is what
`docker run` without a `-e` actually does. That distinction is not cosmetic: `HERMES_TIMEZONE=`
and no `HERMES_TIMEZONE` at all used to fail in completely different ways, and only the second
produced B4b's `unbound variable`. A matrix built on empty strings would have reported the
whole class as fixed while it was not.

## What the stub does that a convenient stub would not

**Onboarding omits `tools`.** Real onboarding's output is not documented, and the entrypoint
set `config.tools.loopDetection` thirteen lines above the guard that created `config.tools` —
a `TypeError` that appears only when the key is absent. A stub that always supplied it would
have made B2 untestable, which is how the defect survived. `OPENCLAW_STUB_ONBOARD_TOOLS=yes`
drives the other shape, so the `||` guard is shown not to clobber an existing object either.

**`config validate` can reject.** It carries a transcription of the upstream schema for the
keys this entrypoint writes. A validator that always exited zero would let every gate case
pass against an entrypoint with no gate in it — so the transcription is fed the shapes it
exists to catch: an unrecognised key inside a strict object, and the bare `env.<NAME>` this
entrypoint used to write.

## The unverified list

Four keys the entrypoint writes are absent from the published schema documentation:

```
tools.exec.security
tools.loopDetection.warningThreshold
tools.loopDetection.criticalThreshold
tools.loopDetection.globalCircuitBreakerThreshold
```

The stub reports them rather than rejecting them, and
`should_report_only_the_known_unverified_keys_when_validate_runs` pins the list. Absent from
one page is weaker evidence than documented as something else, and deleting working
configuration on that basis would be a guess — but a *new* hand-written key cannot be added
now without someone having to decide what it is.

**This is the one thing these checks cannot answer.** The transcription is documentation-
derived; nobody has run the real validator against the real image. If any of those four keys
is genuinely unrecognised upstream, the phase 3 gate will refuse to start a container that
previously worked. Settle it before shipping the image:

```bash
docker run --rm --entrypoint openclaw <image> config schema | jq '.. | keys? // empty' | grep -c security
```

`PLAN.md` § Risks calls for exactly this — *run it against the current config before wiring
the gate* — and it is the acceptance step that is still owed.

## Sensitivity

Against the pre-change `entrypoint.sh`, 56 of the 64 cases fail:

```bash
ENTRYPOINT=/path/to/old/entrypoint.sh HARNESS_REGISTRAR_TIMEOUT=4 \
  .specs/004-entrypoint-startup-correctness/tests/validation-test
```

That is 2/27, 3/9, 1/16 and 2/12 passing.

The eight that pass are regression guards rather than gaps:

| Case | Why it passes against the old file |
|---|---|
| `should_exit_non_zero_when_a_required_variable_is_omitted` | The old file also exited non-zero — with `unbound variable`, or from a `TypeError`. What it did *not* do is any of the other four assertions in the matrix. |
| `should_not_start_the_gateway_when_a_required_variable_is_omitted` | Same. |
| `should_create_the_approvals_file_when_it_is_absent` | Write-if-absent must still write. |
| `should_not_recreate_an_approvals_file_the_operator_deleted` | Deleting the file is how an operator adopts a changed default. |
| `should_skip_onboarding_when_a_config_already_exists` | Unchanged behaviour that the reordering must not have taken away. |
| `should_preserve_an_existing_tools_object_when_onboarding_wrote_one` | The guard is `||`, not an assignment. |
| `should_reject_an_unrecognised_key_when_validate_runs` | Guards the guard: it tests the stub's transcription, not the entrypoint. |
| `should_reject_the_undocumented_env_shape_when_validate_runs` | Same. |

Five more cases used to sit in that list and no longer do. They passed against the old file
for the wrong reason: it crashed on B2 before writing anything, so *absence* satisfied them and
two identical fingerprints proved only that it had crashed twice. Each now asserts that the run
which should have written something did. That is what the sensitivity run is for — a case that
cannot fail is not a case.

## Mutations

```bash
.specs/004-entrypoint-startup-correctness/tests/mutation-check
```

Twenty-seven mutations, one behaviour each, applied to a copy of `entrypoint.sh`. Every one is
caught. It is not part of `run` because it re-runs the suites up to twenty-seven times —
`validation-test` first, and the rest only while nothing has caught the mutation yet.

Each mutation asserts its anchor occurs exactly once in the whole file, and that the mutant
still parses, before it is applied; a bad anchor is reported as a bad anchor rather than as a
caught or uncaught mutation.

The first mutation is the one worth knowing about. `validation runs after the writes` moves
onboarding above the required-variable block, which is where it was — and four cases catch it,
all of them asserting that nothing was written rather than that something failed. Ordering is
the entire content of this change, and only an assertion about state can see it.

## What this change took away from 002, and gave back

`writes-before-validating` is one of 002's mutations: it makes the Slack block write
`channels.slack` *before* it validates its input. 002 caught it with
`should_not_leave_slack_configured_when_slack_allow_from_is_missing`, which runs with the
allowlist unset — and phase 1 now rejects that input before the Slack block runs at all, so the
premature write never happened and the mutation survived.

The guarantee is stronger, and the coverage was still gone. 002 gained
`should_not_leave_slack_configured_when_the_allowlist_lists_no_ids`, which uses `' , , '` — a
value phase 1 passes and the Slack block rejects — so the mutation is caught again. Its
mutation-check reports every mutation caught, as it did before.

The lesson generalises: moving a check earlier can silently retire a case that was watching a
later one. Only running the other specs' mutation-checks found it; their suites stayed green
throughout.

## What still needs a container

- `openclaw config schema` against the real image, to settle the four unverified keys above.
- `openclaw config validate --json` against a config this entrypoint wrote, to confirm the
  transcription is not merely self-consistent.
- `openclaw config get commands.ownerAllowFrom`, and a heartbeat actually arriving on a fresh
  container — the delivery half of B5 is upstream behaviour that no stub can demonstrate.
- What the real `openclaw config validate` prints on failure. The gate passes it through, so
  `should_not_log_a_token_when_the_gate_fails` redacts the four tokens out of it first — but
  that case drives the stub, and only the real binary can say whether it quotes values at all.
