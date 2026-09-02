# Feature: Register the morning briefing through the automations CLI

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

The entrypoint hand-writes `~/.openclaw/cron/jobs.json` to register the morning briefing.
Upstream documents that cron job data is stored in **SQLite**, not a hand-editable JSON
file, and that jobs should be managed exclusively through the CLI or Gateway API.

The git history corroborates it: `284a70b` → revert → `8684128` → `509b77b` →
`0bcddd6 "Fix jobs.json pre-seed to handle object-keyed format"`. That is the signature of
fighting a store that migrated out from under the code.

**The morning briefing — a headline feature in the README — probably never fires, and fails
silently.** This spec replaces the pre-seed with a supported registration path and makes the
outcome verifiable.

There is a constraint that shapes the design: automation mutations require `operator.admin`
and run through the Gateway scheduler, so registration cannot happen before the gateway is
up. A naive substitution of a CLI call for the JSON write would fail at exactly the point
the current code fails, and just as quietly.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| B1a | Cron data lives in SQLite; jobs.json is not a supported registration path | upstream `docs/automation/cron-jobs.md` | doc-verified |
| B1b | Entrypoint hand-writes `~/.openclaw/cron/jobs.json` | `entrypoint.sh:264-285` | internal-contradiction |
| B1c | `catch {}` plus unconditional rewrite would delete every other job in the file | `entrypoint.sh:270`, `:284` | internal-contradiction |
| B1d | The command is `openclaw automations` (`openclaw cron` is an alias) | upstream `docs/cli/cron.md` | doc-verified |
| B1e | All automation mutations require `operator.admin` and go through the Gateway | upstream `docs/cli/cron.md` | doc-verified |
| B1f | Briefing instructions are duplicated in `AGENTS.md` and the job payload | `entrypoint.sh:223-228` vs `:277` | internal-contradiction |

**Falsify before implementing:** `docker exec hermes openclaw cron list`. If
`morning-briefing` is absent, B1a is confirmed in this deployment.

## User Stories

- As the user, I want the morning briefing to actually arrive, so that the feature the
  README promises exists.
- As the operator, I want registration to fail loudly if it does not succeed, so that a
  missing briefing is a visible error rather than silence.
- As the operator, I want to inspect and trigger the job with standard commands, so that I
  can verify it without reading container internals.
- As the operator, I want restarts not to duplicate the job, so that I do not receive N
  briefings after N restarts.
- As the maintainer, I want the briefing instructions in one place, so that the cron payload
  and `AGENTS.md` cannot drift.

## Acceptance Criteria

- [ ] Given a fresh container, when it has started, then `openclaw cron list` shows exactly
      one job named `morning-briefing`.
- [ ] Given the container is restarted five times, when it has started, then
      `openclaw cron list` still shows exactly one `morning-briefing`.
- [ ] Given the job exists, when `openclaw cron run <id>` is invoked, then a briefing is
      delivered to the configured target.
- [ ] Given the job has run, when `openclaw cron runs --id <id>` is invoked, then execution
      history is returned.
- [ ] Given registration fails, when the container starts, then the failure is logged at
      error level with the underlying message, and the gateway still starts.
- [ ] Given the gateway never becomes ready within the timeout, when registration is
      attempted, then it gives up after a bounded number of retries and logs why.
- [ ] Given `HERMES_CRON_SCHEDULE` and `HERMES_TIMEZONE`, when the job is registered, then
      its schedule and timezone match them.
- [ ] Given the container starts, then `~/.openclaw/cron/jobs.json` is no longer written.
- [ ] Given the briefing prompt, then it exists in exactly one place in the repository.

## Structural Impact

### Provisioning
No change.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
- `:264-285` — owned region. The jobs.json block is **deleted**.
- A background registrar is inserted immediately before `:287`, so `exec` is preserved.

### Agent pipeline
No change.

### Agent instructions
- `AGENTS.md` cron section (`:223-228`) — reduced to a pointer. The job payload becomes the
  single source of the briefing instructions (B1f).

### Image & CI
No change.

### Documentation
- `README.md` — document how to verify the job (`openclaw cron list`) and trigger it
  manually (`openclaw cron run`).

## Configuration Contract

| In | Out |
|---|---|
| `HERMES_CRON_SCHEDULE` | automation schedule expression |
| `HERMES_TIMEZONE` | automation `--tz` |
| `HERMES_BRIEFING_CHANNEL` (new, optional) | `--channel` |
| `HERMES_BRIEFING_TO` (new, optional) | `--to` |

`HERMES_BRIEFING_CHANNEL` / `HERMES_BRIEFING_TO` give the briefing an explicit delivery
target. Without them the job relies on implicit routing — the same weakness as review
finding B5 (`heartbeat.target: 'last'` with no `commands.ownerAllowFrom`, so alerts have
nowhere to go on a fresh container). The heartbeat half of B5 is handled in **004**.

## Operability

- Registration logs one line on success (`cron: registered morning-briefing <id>`) and one
  on each failed attempt with the attempt number and the error.
- Operator verification: `openclaw cron list`, `openclaw cron run <id>`,
  `openclaw cron runs --id <id> --limit 50`.
- Registration failure must **not** prevent the gateway from starting — chat access is more
  important than the briefing, and a dead container helps nobody.

## Dependencies

- **Depends on 004** for the early required-vars block guaranteeing `HERMES_CRON_SCHEDULE`
  and `HERMES_TIMEZONE` are present before the registrar runs.

## Open Questions

1. **Registration strategy.** Three options, costed in `PLAN.md` § Implementation Strategy.
   Recommendation: background registrar with a readiness probe, preserving `exec`.
   Confirm before implementing — the alternatives change PID 1 semantics.
2. **Admin authentication.** Mutations require `operator.admin`. Whether a loopback CLI call
   inside the container satisfies this automatically, or needs an explicit token, is
   unverified. **Check first:** start the container, then
   `docker exec hermes openclaw cron list`. If it errors on permissions, the registrar needs
   credentials and this spec grows a task.
3. **Duplicate detection key.** Match on `--name`, since no stable ID exists before the first
   create. If two jobs share a name the CLI may not reject it — confirm behaviour and decide
   whether to delete-then-create instead.
4. **Should the briefing survive a config volume wipe?** Registration is idempotent per
   start, so a wiped volume re-registers. No action needed unless the job carries state.
