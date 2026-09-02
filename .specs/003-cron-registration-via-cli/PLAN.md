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
- Add `wait_for_gateway()` — polls `openclaw gateway status` on a fixed interval with a
  bounded attempt count. No unbounded loops.
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

Both-or-neither: supplying one without the other is a configuration error and should fail
the same way 002's partial Slack config does.

## Task List

1. [ ] runtime-config: **verify the premise first** — start the container as-is and run
       `openclaw cron list`. Record the output in the commit message. If `morning-briefing`
       is present, stop and revise this spec.
2. [ ] runtime-config: verify `operator.admin` from inside the container (SPEC Open
       Question 2). If it fails, add a credentials task before continuing.
3. [ ] runtime-config: extract `BRIEFING_PROMPT` to a single variable.
4. [ ] runtime-config: add `wait_for_gateway()` with bounded retries.
5. [ ] runtime-config: add `register_briefing()` with list-before-create idempotency.
6. [ ] runtime-config: wire the background registrar before `exec`; delete the jobs.json
       block.
7. [ ] instructions: reduce the `AGENTS.md` cron section to a pointer.
8. [ ] tests: restart-idempotency check — start five times, assert exactly one job.
9. [ ] tests: failure-path check — make registration fail, assert the gateway still starts
       and the error is logged.
10. [ ] docs: README verification subsection and the two new environment rows.

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

- `cron: registered morning-briefing <id>` on success.
- `cron: morning-briefing already registered (<id>)` when skipped.
- `cron: registration attempt <n>/<max> failed: <error>` per failure.
- `cron: giving up after <max> attempts; briefing not scheduled` on exhaustion.
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
