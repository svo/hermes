# Feature: The morning briefing follows its configuration

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Split out of [`010`](../010-secondary-readonly-gmail/SPEC.md) § Open Questions 2, where it
> was finding G10. It is a defect in [`003`](../003-cron-registration-via-cli/SPEC.md)'s
> registrar, not in the feature that found it, and it lands before 010.

## Overview

The briefing registrar is presence-only. Once a job named `morning-briefing` exists, no later
start changes it. The schedule, timezone and delivery target are read from the environment
exactly once — on the start that first registers the job — and the prompt is read from the
image the same way. After that, a changed `HERMES_CRON_SCHEDULE`, `HERMES_TIMEZONE`,
`HERMES_BRIEFING_CHANNEL` or `HERMES_BRIEFING_TO` does nothing, and neither does a prompt
change shipped in a new image. The README says the briefing runs "at `HERMES_CRON_SCHEDULE`, in
`HERMES_TIMEZONE`". On any deployment older than its last change to either, it does not.

003 chose presence-only on purpose, and its reason was sound for the alternative it rejected.
Delete-then-create "would destroy a job the operator may have deliberately edited or disabled,
to fix a duplicate that has not been shown to occur" (003 § Open Questions 3). The pinned
OpenClaw offers a third path that 003's documentation did not show: a **declared** automation.
`automations create --declaration-key <key>` is an upsert. If a job with that key exists, it is
brought to the declared schedule, prompt and delivery **in place**: same id, same run history,
and its enabled state untouched. If nothing differs, nothing is written.

That fixes presence-only without reopening what 003 was guarding against. A briefing the
operator disabled stays disabled. What changes is that the environment, not the first start,
decides the schedule.

One complication is specific to existing deployments. A key cannot be added to a job after it
was created, and every job 003 registered was created without one. Those have to be replaced
once, which is the only removal this spec performs.

## Source Findings

`doc-verified` here means checked against OpenClaw's source **at the pinned tag
`v2026.9.2`**, not only against context7, which serves OpenClaw's `main` branch.
`--declaration-key` does not appear in the CLI reference at that tag; it appears in the
command's own option list and in the scheduler it calls. Bumping `openclaw_version` (007) means
re-checking every anchor marked `v2026.9.2` below.

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| R1 | The registrar is presence-only: once a `morning-briefing` is listed, the start returns without comparing or writing anything, so a changed prompt, schedule, timezone or delivery target never reaches a deployment that has already registered | `entrypoint.sh` `register_briefing` (the `lookup_status -eq 0` branch); `README.md` § Morning Briefing ("At `HERMES_CRON_SCHEDULE`, in `HERMES_TIMEZONE`") | internal-contradiction |
| R2 | `automations create --declaration-key <key>` upserts: a job carrying that key within the caller's scope is converged in place instead of duplicated | `v2026.9.2` `src/cli/cron-cli/register.cron-add.ts:93`; `src/cron/service/ops-mutations.ts:333-366` | doc-verified |
| R3 | Convergence covers schedule, payload, delivery and display name. Name, session target, agent and owner are outside it. `enabled` changes only when `--disabled` is passed explicitly, so a disabled job stays disabled | `v2026.9.2` `src/cron/service/jobs.ts:468-543`; `register.cron-add.ts:409-411` | doc-verified |
| R4 | An unchanged declaration writes nothing, and `create` returns `created: false, updated: false` — **but only when the stored schedule carries an explicit stagger.** Without one, the first unchanged declaration after a create, and after every gateway start, writes and returns `updated: true`. An upstream defect: an `undefined` `staggerMs` key fails an `isDeepStrictEqual` | `v2026.9.2` `ops-mutations.ts:368-375`; `src/gateway/server-methods/cron.ts:199-210`; [PLAN](PLAN.md) § The probe, B2 | execution-verified |
| R5 | A key cannot be added to an existing job: the `cron.update` patch type excludes `declarationKey`. A job created without one can be brought under a declaration only by replacing it | `v2026.9.2` `src/cron/types.ts:538-552` | doc-verified |
| R6 | `automations list --all --json` rows carry `declarationKey` only when it is set, alongside `id`, `name` and `enabled` | `v2026.9.2` `server-methods/cron.ts:218-227` | doc-verified |
| R7 | Keys beginning `heartbeat-task:` or `skill-collection-review:` are reserved for the gateway, and a create with one is rejected | `v2026.9.2` `src/cron/system-owned-declaration.ts`; `ops-mutations.ts:310-315` | doc-verified |
| R8 | More than one job carrying the same key within the caller's scope makes the create fail as ambiguous rather than pick one | `v2026.9.2` `ops-mutations.ts:337-339` | doc-verified |

**Verify-locally before implementing:**

```bash
docker exec hermes openclaw automations create --help | grep -- --declaration-key
docker exec hermes openclaw automations list --all --json
```

The first confirms the image's binary carries R2. The second shows the deployment's
`morning-briefing` with no `declarationKey`, which is R5's premise and the reason adoption
exists.

## User Stories

- As the operator, I want a changed `HERMES_CRON_SCHEDULE`, `HERMES_TIMEZONE` or briefing
  target to change the briefing on the next start, so that the variables mean what the README
  says they mean.
- As the maintainer, I want a prompt change shipped in a new image to reach existing
  deployments on their next start, so that a feature like 010 needs no manual step to arrive.
- As the operator, I want a briefing I have disabled to stay disabled across restarts and
  upgrades, so that turning it off sticks.
- As the operator, I want no start to leave me with two briefings, so that the change to
  declarations does not cost what 003 prevented.
- As the operator, I want the log to say whether a start created, updated or left the briefing
  alone, so that a configuration change can be confirmed without reading the job.

## Acceptance Criteria

### Declared registration

- [ ] Given an empty automation store, when the container has started, then exactly one job
      named `morning-briefing` exists. It carries the declaration key `hermes:morning-briefing`
      and the schedule, timezone, prompt and delivery the environment specifies. 003's criteria
      continue to hold.
- [ ] Given a declared job and an unchanged environment and image, when the container restarts
      five times, then there is still exactly one `morning-briefing`, its id is unchanged, and
      no start wrote to it.
- [ ] Given a declared job, when the container restarts with a different `HERMES_CRON_SCHEDULE`,
      `HERMES_TIMEZONE`, delivery target or prompt, then the same job — same id — carries the
      new value.
- [ ] Given a declared job with a delivery target, when the container restarts with
      `HERMES_BRIEFING_CHANNEL` and `HERMES_BRIEFING_TO` both removed, then the job's delivery
      is what a fresh registration without them produces.
- [ ] Given a declared job the operator has disabled, when the container restarts, with or
      without a changed environment, then the job is still disabled.
- [ ] Given a declared job whose schedule, prompt or delivery the operator changed with
      `automations edit`, when the container restarts, then the environment's values replace
      the edit (Open Question 1).
- [ ] Given the key, then it begins with neither reserved prefix (R7).

### Adopting a job registered before this change

- [ ] Given a store holding a `morning-briefing` with no declaration key, when the container
      has started, then exactly one `morning-briefing` exists, and it carries the key.
- [ ] Given that unkeyed job was disabled, then the declared job is disabled.
- [ ] Given more than one unkeyed `morning-briefing` — the duplicate 003 does not defend
      against, from two containers sharing a volume — then all of them are replaced by one
      declared job. That job is enabled if any of them was.
- [ ] Given the unkeyed job cannot be removed, then the failure is logged, the declared job
      remains, and the next start retries the removal. Adoption declares first and removes
      second, so a store that held a `morning-briefing` is never left without one, whether the
      start succeeds or fails (Open Question 2).
- [ ] Given the automation listing cannot be read or parsed, then on that attempt nothing is
      created and nothing is removed, and the attempt is retried within the existing budget.
      Declaring without knowing whether an unkeyed job exists is how a second briefing would
      appear.
- [ ] Given a job named `morning-briefing` that already carries a different declaration key,
      then it is left alone. It is not this registrar's.

### Failure and logging

- [ ] Given every terminal path of the registrar, then it emits exactly one line — the
      invariant 003's harness waits on. The terminal lines distinguish *created*, *updated* and
      *unchanged*. Removing an unkeyed job adds one non-terminal line naming its id.
- [ ] Given `create`'s output cannot be parsed, then the terminal line says the declaration
      succeeded with its outcome unknown, rather than guessing which.
- [ ] Given registration fails, then the gateway still starts. 003's asymmetry is unchanged.

## Structural Impact

### Provisioning
No change. The pinned `openclaw` (`2026.9.2`) already has `--declaration-key`.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
- **`briefing_create_args`** — gains `--exact` and `--declaration-key hermes:morning-briefing`.
  `--exact` is not cosmetic: without an explicit stagger, an unchanged declaration writes on
  the first start after every restart (R4).
- **`register_briefing` / `lookup_briefing_job`** — look-up-then-create becomes
  adopt-then-declare. The lookup stays, but only to find unkeyed `morning-briefing` jobs to
  adopt. The declaration runs on every start, because convergence is the point and R4 makes an
  unchanged one free.
- `create` now runs on every start, and the CLI warns on stderr whenever `--agent` is omitted
  (`register.cron-add.ts:392-402`). Its stdout must be read apart from its stderr if its JSON
  is to be parsed.
- The prompt, the both-or-neither delivery check and the fork before `exec` are unchanged.

### Agent pipeline
No change.

### Agent instructions
No change. 011 changes how the prompt reaches the job, not the prompt.

### Image & CI
No change.

### Documentation
- `README.md` § Morning Briefing — the log-line table, the paragraph that says the job "is
  looked up by name before it is created", and a statement that the environment is the source
  of truth for schedule, timezone and target, and that a disabled briefing stays disabled.

## Configuration Contract

No new variables.

| In | Out |
|---|---|
| `HERMES_CRON_SCHEDULE`, `HERMES_TIMEZONE`, `HERMES_BRIEFING_CHANNEL`, `HERMES_BRIEFING_TO` | Converged into the job on **every** start, not only the first |
| The image's briefing prompt | Likewise |
| — | The job carries `declarationKey: hermes:morning-briefing` and an explicit zero stagger: it runs at exactly `HERMES_CRON_SCHEDULE`, with no stagger even for an hourly top-of-hour schedule |

## Operability

| Line | Meaning |
|---|---|
| `cron: registered morning-briefing <id>` | Created on this start (unchanged wording) |
| `cron: updated morning-briefing <id>` | Existed; schedule, prompt or delivery changed to match this start |
| `cron: morning-briefing unchanged (<id>)` | Existed and already matched; nothing was written |
| `cron: declared morning-briefing <id>; outcome unavailable` | The declaration landed — the job is listed with the key — but `create`'s output could not be read to say which of the three it was |
| `cron: replaced unkeyed morning-briefing <id>` | Non-terminal. A job registered before this change was removed after its declared successor was in place |
| `cron: could not remove unkeyed morning-briefing <id>: <error>; the next start will retry` | Non-terminal. The declared job is in place; the leftover is the window of two briefings Open Question 2 accepts |
| `cron: giving up after <n> attempts; briefing left as it was (<why>)` | A briefing exists — declared, or one an older image registered — but could not be converged this start, so it runs on its previous configuration |
| `cron: giving up after <n> attempts; briefing declared but not confirmed (<why>)` | `create` reported success, but no listing this start showed a job carrying the key. A declared job may exist; this start cannot say. Added at implementation, when review found that the two lines above would each be false here |
| `cron: giving up after <n> attempts; briefing not scheduled (<why>)` | 003's line, kept for the one state it is true of: no briefing was listed and nothing was declared |

`cron: morning-briefing already registered (<id>)` is retired. It described presence, which is
no longer the question.

**Verifying it:**

```bash
docker exec hermes openclaw cron list --all --json \
  | jq '.jobs[] | select(.name == "morning-briefing") | {id, declarationKey, enabled}'
```

Exactly one row, carrying the key.

**Changing it:** set the variable and recreate the container. To stop the briefing, disable it
with `openclaw cron disable <id>`; that survives restarts and upgrades. Anything changed with
`automations edit` other than the enabled state is replaced on the next start (Open
Question 1).

## Dependencies

- **003** — owns the registrar region and its suite; both change here.
- **004** — the phase ordering the registrar sits after.
- **007** — pins the `openclaw` version every `v2026.9.2` anchor above is checked against.
- **Blocks 010** — 010's briefing step reaches existing deployments only through this.

## Planned Crossings

Declared now rather than discovered later, following 007 and 008:

| Region | Owner | What 011 does there |
|---|---|---|
| The briefing registrar — `briefing_create_args`, `lookup_briefing_job`, `register_briefing` | 003 | Rewrites the lookup and registration logic. The prompt, the delivery check, the timeouts and the fork placement are untouched |
| `tests/stub-openclaw` and its cases | 003 | The stub learns `--declaration-key` (upsert by key, no-op when equal, enabled preserved unless `--disabled`), `automations remove`, and `declarationKey` on list rows. `registration-test` gains the cases above. Any case that pinned `already registered` changes with the line it pinned |

## Open Questions

All three were answered before planning. The answers are recorded here rather than in a commit
message, because the first constrains what a later change may do.

1. **Are `automations edit` changes to schedule, prompt or delivery overwritten on the next
   start?** *Answered: yes, the environment wins.* Declaring on every start means an operator
   who edits the job's schedule by hand sees it reverted, at the latest within a week, when
   watchtower recreates the container. The way to change the briefing is the variable.
   - It is the rule 008 and 009 already apply to `openclaw.json`: the configuration is a
     function of the environment.
   - The edit 003 was protecting — disabling — is preserved (R3).

   Two alternatives were considered and not taken. Both need a fingerprint, kept on the volume,
   of what the registrar last wrote:
   - converge only while the job still matches the fingerprint, so hand edits survive;
   - converge regardless, and use the fingerprint only to log that a hand edit was replaced.

   That is state of its own, for an edit path nobody has asked for. A later change that wants
   hand edits to survive has to bring that state with it.
2. **Adoption order.** *Answered: declare, then remove.* Declare-then-remove never leaves the
   store without a briefing, at the cost of a moment with two — longer if the removal fails,
   until a later start retries it. Remove-then-declare was rejected: it never has two, but a
   failed declare leaves none until a later attempt succeeds. A second briefing is visible, and
   the log names the leftover job's id. A missing one is the silent failure 003 was written to
   end. Removal discards the unkeyed job's run history, which OpenClaw keeps for seven days
   anyway.
3. **Declare, or edit in place?** *Answered: declare.* `automations edit <id> --message --cron
   --tz --announce --channel --to` exists at the pinned version, and editing would need no
   adoption: same job, same history. But the registrar would then compare the stored job with
   the environment itself, every start. It would also have to work out which `--clear-channel` /
   `--clear-to` flags a removed target needs. And it would depend on the shape of
   `automations get` JSON, which no documentation fixes. A declaration does all three
   server-side, under the scheduler's lock, and the one-time adoption is the price.
