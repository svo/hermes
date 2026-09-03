# Plan: Register the morning briefing through the automations CLI

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

Delete the jobs.json block. Register through `openclaw automations` instead. The whole
difficulty is *when*.

Automation mutations require `operator.admin` and are served by the Gateway scheduler, so
registration cannot precede `exec openclaw gateway` at `:287`. Three designs:

| | Approach | PID 1 | Verdict |
|---|---|---|---|
| **(a)** | Background registrar: `( wait_for_ready; register ) &` then `exec` | gateway (unchanged) | **Chosen** |
| (b) | Gateway in background, register, then `wait` | bash | Rejected — degrades `docker stop` signal handling unless traps are added, for no benefit |
| (c) | Do not register from the entrypoint; document a one-time operator command | gateway | Rejected as default — breaks the README's "configures itself on first run" property. Kept as the documented fallback |

**(a)** keeps `exec`, so the gateway remains PID 1 and `--restart unless-stopped` continues
to behave. The registrar is a detached subshell that polls readiness, registers once, logs,
and exits. It cannot block or kill the gateway.

Idempotency is a **query before create**, not a blind create — a create-and-ignore-errors
approach would silently accumulate duplicates if the CLI does not reject same-name jobs
(SPEC Open Question 3).

The failure mode is deliberately asymmetric: a failed registration logs an error and leaves
the gateway running. A container that refuses to start because a briefing could not be
scheduled would be a worse outcome than a missing briefing.

## Layer Changes

### Provisioning
None.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned region: `:264-285` (deleted) and the insertion point before `:287`.

- Delete the entire jobs.json `node -e` block, including the `catch {}` that could wipe
  sibling jobs (B1c).
- Add `wait_for_gateway()` — polls on a fixed interval with a bounded attempt count. No
  unbounded loops. **Implemented against `openclaw gateway health --port`, not
  `openclaw gateway status`:** the gateway listens on 3000, `status` has no documented
  `--port` and would resolve the default, and `health` is the documented port-targeted
  liveness-and-readiness probe. A `timeout` bounds a probe that connects and then hangs,
  which a retry budget alone would not.
- Add `register_briefing()`:
  1. `openclaw automations list` → if a job named `morning-briefing` exists, log and return.
  2. Otherwise `openclaw automations create "$HERMES_CRON_SCHEDULE" "$BRIEFING_PROMPT"
     --name morning-briefing --tz "$HERMES_TIMEZONE" --session isolated` plus
     `--announce --channel "$HERMES_BRIEFING_CHANNEL" --to "$HERMES_BRIEFING_TO"` when both
     are set.
  3. Log the outcome either way.
- Invoke as `( wait_for_gateway && register_briefing ) &` on the line immediately before
  `exec openclaw gateway`.
- Define `BRIEFING_PROMPT` once, above both use sites.
- **Do not** touch lines 1–99 (004), 248–262 (002), or 12/287's flags (007).

### Agent instructions
- Replace the `AGENTS.md` cron section (`:223-228`) with a one-line pointer: the briefing is
  a registered automation; its instructions live in the job payload. This removes the
  duplication in B1f and the risk that the agent runs the briefing twice.

### Documentation
- `README.md` — a verification subsection: `openclaw cron list`, `openclaw cron run <id>`,
  `openclaw cron runs --id <id>`. Document `HERMES_BRIEFING_CHANNEL` / `HERMES_BRIEFING_TO`
  in the environment table as optional.

## Configuration Contract

| In | Out |
|---|---|
| `HERMES_CRON_SCHEDULE`, `HERMES_TIMEZONE` (required — enforced by 004) | automation schedule and `--tz` |
| `HERMES_BRIEFING_CHANNEL` + `HERMES_BRIEFING_TO` (optional, both-or-neither) | `--announce --channel --to` |
| `HERMES_CRON_READY_ATTEMPTS`, `HERMES_CRON_REGISTER_ATTEMPTS` (optional) | the two retry budgets, so a slow host can raise them rather than lose the briefing |
| `HERMES_CRON_CALL_TIMEOUT` (optional) | the per-call bound, so a stalled gateway cannot hold the registrar open forever |

All three are rejected at startup unless they are positive whole numbers. A value bash cannot
compare would skip every loop iteration and give up immediately, blaming the gateway.

Both-or-neither: supplying one without the other is a configuration error and should fail
the same way 002's partial Slack config does.

## Task List

1. [ ] runtime-config: **verify the premise first** — start the container as-is and run
       `openclaw cron list`. Record the output in the commit message. If `morning-briefing`
       is present, stop and revise this spec.

       **Not done — could not be run.** There is no `hermes` container and no `openclaw`
       binary on the host this was implemented on. The command is carried into SPEC Open
       Question 2 for whoever has a deployment, and the change proceeded on the two findings
       that hold without it: B1b and B1c are internal contradictions, true whatever upstream
       does. Even if the premise turns out to be wrong and the job does register today, the
       `catch {}` at the old `:340` still silently discards a corrupt store and the
       unconditional rewrite at `:354` still drops every sibling job.
2. [ ] runtime-config: verify `operator.admin` from inside the container (SPEC Open
       Question 2). If it fails, add a credentials task before continuing.

       **Not done — same reason,** and the documentation points the wrong way rather than
       being silent; see SPEC Open Question 2. The registrar is written to be correct either
       way: any non-zero exit is a failure, the underlying message is logged verbatim, and
       the attempts are bounded. If a deployment shows the mutation refused, the credentials
       task lands then — and it touches the bind flags 007 owns.
3. [x] runtime-config: extract `BRIEFING_PROMPT` to a single variable.
4. [x] runtime-config: add `wait_for_gateway()` with bounded retries.
5. [x] runtime-config: add `register_briefing()` with list-before-create idempotency.
6. [x] runtime-config: wire the background registrar before `exec`; delete the jobs.json
       block.
7. [x] instructions: reduce the `AGENTS.md` cron section to a pointer.
8. [x] tests: restart-idempotency check — start five times, assert exactly one job.
9. [x] tests: failure-path check — make registration fail, assert the gateway still starts
       and the error is logged.
10. [x] docs: README verification subsection and the new environment rows — four, not the
        two this task anticipated: the two delivery variables plus the two retry budgets.

Tasks 3–10 are verified by `tests/`, which runs the real `entrypoint.sh` against a stub
`openclaw`; `tests/README.md` says what that can and cannot establish.

## Testing Strategy

No test framework exists. Verification is behavioural, through the CLI the fix now uses:

- **Premise test** (task 1) — the falsification step. This is the most valuable test in the
  spec: it proves the bug before the fix and proves the fix after.
- **Idempotency** — `for i in $(seq 5); do docker restart hermes; done`, then
  `openclaw cron list | grep -c morning-briefing` must be `1`.
- **Trigger** — `openclaw cron run <id>` delivers; `openclaw cron runs --id <id>` shows it.
- **Failure path** — point `HERMES_BRIEFING_TO` at an invalid target, assert a non-zero
  registration result is logged and `openclaw gateway status` still reports running.
- **Readiness timeout** — start the registrar against a gateway that never comes up
  (temporarily break the bind), assert bounded retries and a clear give-up message.
- **Negative** — assert `~/.openclaw/cron/jobs.json` is absent after startup.
- Naming: `should_<behaviour>_when_<condition>`.

## Operability Plan

As implemented, with the parenthetical each line actually carries — a log assertion written
from this list rather than from the code would otherwise never match:

- `cron: waiting for gateway (up to <n> attempts)` once, when the registrar starts.
- `cron: registered morning-briefing <id>` on success, or `… <id unavailable>` when the
  listing carried no id this recognised.
- `cron: morning-briefing already registered (<id>)` when skipped.
- `cron: registration attempt <n>/<max> failed: <error>` per failure, carrying the captured
  output of the failing call verbatim.
- `cron: giving up after <max> attempts; briefing not scheduled (<why>)` on exhaustion. The
  reason is required: the spec asks it to log *why*, and "the gateway never became ready" and
  "the create was refused" call for different operator responses.
- Operator: `openclaw cron list`, `openclaw cron runs --id <id> --limit 50`.

## Risks and Mitigations

- **Risk:** the background subshell outlives a failed gateway and retries forever.
  → **Mitigation:** bounded attempts, hard cap, explicit give-up log.
- **Risk:** `operator.admin` is not satisfied by a loopback CLI call, so registration fails
  in a new way. → **Mitigation:** task 2 checks this *before* the implementation is written.
- **Risk:** two containers on the same volume both register, creating duplicates.
  → **Mitigation:** list-before-create narrows it; a genuine race is out of scope for a
  single-container deployment. Note the limitation rather than over-engineering.
- **Risk:** `--session isolated` behaves differently from the old payload's
  `sessionTarget: 'isolated'`. → **Mitigation:** compare a triggered run's output against
  the intended briefing before closing the task.
- **Risk:** removing the `AGENTS.md` cron text changes behaviour if the automation silently
  fails — the agent would no longer have a fallback instruction. → **Mitigation:** acceptable
  and intended. A silent fallback is what let B1 hide; task 9 makes the failure loud instead.
- **Risk:** the premise is wrong and the job does register today. → **Mitigation:** task 1.
  If so, this spec reduces to deleting the `catch {}` wipe hazard (B1c) — still worth doing.
