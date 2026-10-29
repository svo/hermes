# 011 checks

Verification for [SPEC.md](../SPEC.md) and [PLAN.md](../PLAN.md). No image, no credentials, no
Anthropic key: the real `entrypoint.sh` runs against a stub `openclaw`, and the cases read the
automation store that stub keeps.

```bash
.specs/011-briefing-converges/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. 003's, plus `seed_store`, `store_edit`, `store_field_of` and `terminal_line_count`. |
| `convergence-test` | SPEC § Declared registration, and § Failure and logging. |
| `adoption-test` | SPEC § Adopting a job registered before this change. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | 003's stub, copied: `onboard`, `gateway`, `gateway health`, `config …`, `automations list`, `automations create`, `automations remove`. Since copied, it can hang `list`, `create` and `remove`, and print one page of several. |

Forty-two cases: 23 in `convergence-test`, 19 in `adoption-test`. 003's suite still runs
against the same registrar and still owns readiness, budgets, timeouts, delivery validation, the
prompt and the one-line contract. 011 changed nine of its cases, and folded two into one; PLAN
§ Testing Strategy lists them.

## Every convergence case is a restart

A single start cannot show convergence. The job has to exist with one configuration before a
start with another means anything. So nearly every case here runs the entrypoint at least twice
over one store, or once over a store seeded the way an older image, or an operator's
`automations edit`, would have left it. A changed prompt is tested that way: the prompt lives in
the image, so a new one arrives as a new image over an old store.

"No start wrote to it" is asserted by counting, not by comparing. The stub appends a line to
`writes` beside its store only when it really writes, so five unchanged restarts leave the count
where the first start put it.

## The stub models the upstream defect `--exact` avoids

The pinned gateway rewrites a job stored without an explicit stagger on its first unchanged
declaration after every restart, and reports it `updated` (PLAN § The probe, B2). The stub does
the same, once per run, because each run of the entrypoint is one gateway lifetime here. A
registrar that dropped `--exact` would write on every start and never log `unchanged`, and
`should_write_nothing_when_five_restarts_change_nothing` would fail. `mutation-check` drops the
flag to prove it.

## Red baseline

Against the pre-011 entrypoint, with these stubs, **40 of the 42 cases fail**:

```bash
ENTRYPOINT=/path/to/pre-011/entrypoint.sh HARNESS_REGISTRAR_TIMEOUT=40 \
  .specs/011-briefing-converges/tests/convergence-test
ENTRYPOINT=/path/to/pre-011/entrypoint.sh HARNESS_REGISTRAR_TIMEOUT=40 \
  .specs/011-briefing-converges/tests/adoption-test
```

That is 2 passed / 21 failed and 0 passed / 19 failed. Neither of the two that pass is a case
that asserts nothing happens. Each guards a way the new registrar could break that the old
one could not:

- `should_read_the_outcome_when_create_warns_on_stderr`. The old registrar never parsed
  `create`'s output, so a warning on stderr could not break it. The new one parses that output,
  and the `merges stderr into the outcome` mutation is what this case catches.
- `should_read_a_listing_larger_than_an_environment_variable_can_hold`. The old registrar
  also passed the listing through the environment and failed to parse it. It then fell back to
  the plain listing, found no briefing, and created one. The new registrar has no fallback, so
  the size limit would stop it on every start.

## What review added

An independent review of the registrar, run once this suite was green, reproduced four defects
the suite had not caught. Each now has a case, and three have a mutation:

- **A timed-out create was logged with the `--agent` warning as its reason.**
  `should_say_the_declaration_timed_out_when_create_never_answers` covers it. The stub could
  not hang a create until then.
- **"Briefing not scheduled" was false** after an adoption whose declaration failed, and after a
  declaration that was never confirmed. These cases cover it:
  `should_leave_the_unkeyed_briefing_running_when_the_declaration_fails` and
  `should_say_the_declaration_is_unconfirmed_when_giving_up_after_create_said_yes`.
- **A renamed declared job was missed**, and beside a disabled leftover the start switched it
  off. `should_recognise_the_declared_briefing_when_the_operator_renamed_it` covers it.
- **A listing over 128 KiB never reached the parser**, because it went through an environment
  variable. `should_read_a_listing_larger_than_an_environment_variable_can_hold` covers it.
  This one has no mutation, because putting the variable back is a two-line change. It was
  checked by hand instead: with the variable, the case fails.

The stub's rows are about 150 bytes, where a real job is about 1.3 KB, so the size limit sat out
of the stub's reach. The large-listing case pads its rows for that reason.

## Mutations

```bash
HARNESS_REGISTRAR_TIMEOUT=200 .specs/011-briefing-converges/tests/mutation-check
```

Eighteen mutations, one behaviour each, applied to a copy of `entrypoint.sh`, and every one is
caught. `convergence-test` runs first, and `adoption-test` only when nothing has caught the
mutation yet. It is not part of `run`, because it re-runs the suites once per mutation.

The eleven PLAN § Sensitivity names:

- declares without the key
- declares without `--exact`
- removes before declaring
- removes without confirming
- removes a foreign-keyed job
- drops `--disabled` on adoption
- passes `--disabled` whenever any unkeyed job is disabled
- tolerates a bare-array listing
- merges stderr into the outcome
- reports every outcome as registered
- declares again after a declare that succeeded

Seven more, for behaviour found while building or reviewing:

- matches the declared job by name as well as key
- reads one page as the whole store
- drops the id from the terminal line
- calls a briefing left running unscheduled
- calls an unconfirmed declaration something it is not known to be
- takes the reason from stderr when the JSON has one
- reports a timeout as whatever stderr held

Each mutation asserts its anchor occurs exactly once, and that the mutant still parses, before it
is scored. The parse check earned its place on the first run. `drops --disabled on adoption`
deleted the only line in an `if`, so its mutant did not parse and could not be scored. It now
replaces the line with `:`.

The suites run under a tighter wait here (`HARNESS_REGISTRAR_TIMEOUT=200`, ten seconds), so the
cases that hang a call give the registrar one attempt instead of two. Two create timeouts and a
retry sleep would not fit in ten seconds.
