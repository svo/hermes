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

- [x] Given a fresh container, when it has started, then `openclaw cron list` shows exactly
      one job named `morning-briefing`.
- [x] Given the container is restarted five times, when it has started, then
      `openclaw cron list` still shows exactly one `morning-briefing`.
- [ ] Given the job exists, when `openclaw cron run <id>` is invoked, then a briefing is
      delivered to the configured target.
- [ ] Given the job has run, when `openclaw cron runs --id <id>` is invoked, then execution
      history is returned.

The two that remain need a running container and a delivery target. Everything else is
verified by `tests/`, which runs the real `entrypoint.sh` against a stub `openclaw`;
`tests/README.md` § Sensitivity says what that establishes and what it cannot.
- [x] Given registration fails, when the container starts, then the failure is logged at
      error level with the underlying message, and the gateway still starts.
- [x] Given the gateway never becomes ready within the timeout, when registration is
      attempted, then it gives up after a bounded number of retries and logs why.
- [x] Given `HERMES_CRON_SCHEDULE` and `HERMES_TIMEZONE`, when the job is registered, then
      its schedule and timezone match them.
- [x] Given the container starts, then `~/.openclaw/cron/jobs.json` is no longer written.
- [x] Given the briefing prompt, then it exists in exactly one place in the repository.

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
| `HERMES_CRON_READY_ATTEMPTS` (new, optional, default `60`) | readiness poll budget |
| `HERMES_CRON_REGISTER_ATTEMPTS` (new, optional, default `5`) | registration attempt budget |
| `HERMES_CRON_CALL_TIMEOUT` (new, optional, default `30`) | per-call wall-clock bound |

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

Three of the four were answered before implementation and are recorded here rather than in the
commit message, because they constrain what a later change may do. The second could not be
answered without a running container, and is left open with the check that would close it.

1. **Registration strategy.** *Answered: (a), the background registrar.* It is the only one of
   the three that keeps `exec`, so the gateway stays PID 1 and `--restart unless-stopped` keeps
   behaving. It also gives the asymmetry this spec asks for structurally rather than by
   convention: the registrar is forked *before* `exec`, so a registration failure cannot stop
   the gateway starting — there is no code path by which it could.

   The one thing it costs is that the registrar's failure is reported after the gateway is
   already serving, so it is a log line rather than a non-zero exit. The both-or-neither check
   on `HERMES_BRIEFING_CHANNEL` / `HERMES_BRIEFING_TO` is therefore *not* in the registrar: a
   partial delivery target is a configuration error, so it is validated synchronously before
   the fork and exits non-zero, the way 002's partial Slack config does.

2. **Admin authentication.** *Open.* It could not be settled from the documentation, and the
   evidence points the wrong way rather than being merely absent:

   - The automatic same-user CLI credential is documented as being prepared on a **loopback**
     start. This container onboards and serves with `--gateway-bind lan` / `--bind lan`, and
     upstream states that binding beyond loopback "is blocked without authentication".
   - The documented hello-ok payload for an operator device token carries `operator.read`, and
     `operator.admin` is described as an escalation that must be approved — not a default.
   - Neither the error text nor the exit code for an `operator.admin` refusal is documented
     anywhere, so nothing can be string-matched against.

   The implementation is written to be correct either way rather than to guess: registration
   is attempted, any non-zero exit is treated as failure, the captured output is logged
   verbatim, and the attempts are bounded. If the CLI does not hold `operator.admin` here, the
   operator sees `cron: registration attempt 1/5 failed: <the real message>` rather than
   silence — which is already better than what this spec replaces.

   **The check that closes this, and the one that closes the premise (task 1):**

   ```bash
   docker exec hermes openclaw cron list          # premise: is morning-briefing there?
   docker exec hermes openclaw automations create "0 8 * * *" test --name probe && \
     docker exec hermes openclaw automations remove <jobId>
   docker logs hermes | grep '^cron:'
   ```

   Neither could be run where this was implemented: there is no `hermes` container and no
   `openclaw` binary on that host. If the mutation is refused for permissions, this spec grows
   a credentials task — most likely `gateway.auth` configured deterministically at onboard
   time, which touches the bind flags that **007** owns.

3. **Duplicate detection key.** *Answered: match on `--name`, and pass `--all`.* Nothing
   upstream says names are unique, that `create` upserts, or that a duplicate name is rejected,
   so list-before-create is the whole defence and a blind create would accumulate a job per
   restart. `--all` is not optional: `automations list` shows only enabled jobs (doc-verified),
   so a *disabled* `morning-briefing` would read as absent and be duplicated by the next start.

   Delete-then-create was rejected. It would destroy a job the operator may have deliberately
   edited or disabled, to fix a duplicate that has not been shown to occur.

   One limitation is worth stating rather than engineering around: automation listings are
   filtered by caller scope, so a job created by a *different* principal can be invisible to
   the registrar and duplicated anyway. Every start of this image lists and creates as the same
   principal, so it does not arise here — but two containers sharing one config volume are not
   defended against, as PLAN.md § Risks and Mitigations already notes.

4. **Should the briefing survive a config volume wipe?** *Answered: no action needed.*
   Registration is idempotent per start and carries no state of its own, so a wiped volume
   simply re-registers on the next start.

   A wiped volume is in fact the *better* case. The one that needed handling is a volume that
   still holds the `~/.openclaw/cron/jobs.json` this spec stops writing. That file is not
   deleted — removing a file a previous version wrote to an operator's volume is not something
   this change was asked to do — but it is inert, and the README says so.
