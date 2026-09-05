# Feature: Entrypoint startup correctness

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

The entrypoint validates its required environment variables at line 77 — after onboarding
has run, after Google service-account credentials have been written, and after the entire
OpenClaw config has been mutated. Several failure paths therefore produce a crash, a
half-configured container, or silent data loss instead of a clear error.

Four defects, all small, all in the first hundred lines or the first `node -e` block:

- `config.tools` is dereferenced 13 lines before the guard that says it might not exist.
- Setting `TELEGRAM_BOT_TOKEN` without `TELEGRAM_ALLOW_FROM` crashes with a `TypeError`,
  and the README documents the opposite behaviour as a supported workflow.
- `export TZ="${HERMES_TIMEZONE}"` on line 4 under `set -u` aborts before the friendly
  missing-variable message can ever print.
- `ANTHROPIC_API_KEY` is absent from `required_vars`, and `JSON.stringify` drops undefined
  values — so restarting without it silently deletes the persisted key from the config.

This spec makes startup fail fast, fail loudly, and never destroy persisted state.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| B2 | `config.tools.loopDetection` written before `config.tools = config.tools \|\| {}` | `entrypoint.sh:51` vs `:64` | internal-contradiction |
| B3a | `process.env.TELEGRAM_ALLOW_FROM.split` throws when unset | `entrypoint.sh:241` | execution-verified |
| B3b | README documents messaging without `TELEGRAM_ALLOW_FROM` as a supported workflow | `README.md:107` | internal-contradiction |
| B3c | README claims a `pairing` fallback; `dmPolicy` is hardcoded `allowlist` | `README.md:105` vs `entrypoint.sh:240` | internal-contradiction |
| B4a | Validation runs after onboarding, credential write, and config mutation | `entrypoint.sh:77-99` | internal-contradiction |
| B4b | `export TZ` under `set -u` aborts before the friendly check | `entrypoint.sh:4` | execution-verified |
| B4c | `ANTHROPIC_API_KEY` missing from `required_vars`; undefined value silently drops the key | `entrypoint.sh:71`, `:77-86` | execution-verified |
| B5 | `heartbeat.target: 'last'` with no `commands.ownerAllowFrom` | `entrypoint.sh:40` | doc-verified |
| B6 | `exec-approvals.json` rewritten unconditionally every start | `entrypoint.sh:21-28` | internal-contradiction |
| D2 | ~15 keys hand-written into strict zod schemas with no validation step | `entrypoint.sh:30-75` | doc-verified |

## User Stories

- As the operator, I want a missing variable to produce a named error before anything is
  written, so that a typo does not leave a half-configured container.
- As the operator, I want a restart without `ANTHROPIC_API_KEY` to fail loudly rather than
  silently erase the key I configured earlier.
- As the operator, I want an incomplete Telegram configuration to tell me which variable is
  missing, instead of a Node stack trace.
- As the operator, I want the config validated against OpenClaw's schema before the gateway
  starts, so that an upstream key rename is a clear startup error rather than a brick.
- As the operator, I want approvals I tighten at runtime to survive a restart.
- As the user, I want heartbeat alerts to have a delivery target on a fresh container.

## Acceptance Criteria

- [ ] Given any required variable is unset, when the container starts, then it exits
      non-zero listing every missing variable, **before** onboarding, credential writing, or
      config mutation.
- [ ] Given `HERMES_TIMEZONE` is unset, when the container starts, then the error is the
      friendly missing-variables list, not `unbound variable`.
- [ ] Given `ANTHROPIC_API_KEY` is unset, when the container starts, then it is reported as
      missing and the persisted config is left untouched.
- [ ] Given a previously configured container restarted without `ANTHROPIC_API_KEY`, when
      startup fails, then `openclaw.json` still contains the original key.
- [ ] Given `TELEGRAM_BOT_TOKEN` is set and `TELEGRAM_ALLOW_FROM` is not, when the container
      starts, then it exits non-zero with a named error and no stack trace.
- [ ] Given the config-mutation block runs, when `config.tools` is absent from the
      onboarded config, then it is created before first use and no `TypeError` occurs.
- [ ] Given configuration completes, when `openclaw config validate` runs, then it exits
      zero; a non-zero result aborts startup with the validator's message.
- [ ] Given an operator has edited `exec-approvals.json`, when the container restarts, then
      their edits are preserved.
- [ ] Given a fresh container with no prior conversation, when a heartbeat fires, then it
      has a resolvable delivery target.
- [ ] Given the README, then it documents the actual Telegram behaviour — no `pairing`
      fallback, `TELEGRAM_ALLOW_FROM` required with the token.

## Structural Impact

### Provisioning
No change.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned region: `:1-99`, plus ordering within the first `node -e` block (`:30-75`).

- Move the `required_vars` block to the top, before `export TZ`.
- Add `ANTHROPIC_API_KEY` to `required_vars`; add `TELEGRAM_ALLOW_FROM` and
  `SLACK_ALLOW_FROM` as conditionally required (rule supplied by 002).
- Move the `config.tools` guard above its first use.
- Write `exec-approvals.json` only when absent.
- Set `commands.ownerAllowFrom` from the configured channel allowlists.
- Add an `openclaw config validate` gate after the config block, before `exec`.

### Agent pipeline / instructions
No change.

### Documentation
- `README.md:105-107` — correct the Telegram DM-policy description.
- Environment table — mark `ANTHROPIC_API_KEY` required and note that startup validates
  everything up front.

## Configuration Contract

Unconditionally required: `ANTHROPIC_API_KEY`, `HERMES_VIBE`, `HERMES_TONE`,
`HERMES_USER_NAME`, `HERMES_TIMEZONE`, `HERMES_LOCALE`, `HERMES_CRON_SCHEDULE`,
`HERMES_QUIET_HOURS_START`, `HERMES_QUIET_HOURS_END`.

Conditionally required: `TELEGRAM_ALLOW_FROM` with `TELEGRAM_BOT_TOKEN`; `SLACK_APP_TOKEN`
and `SLACK_ALLOW_FROM` with `SLACK_BOT_TOKEN`.

New invariant: **no write of any kind occurs before validation passes.**

## Operability

- A single startup error listing every missing variable at once — not one per run.
- The `openclaw config validate` failure surfaces the validator's own message, which names
  the offending key path.
- Verification: `openclaw config get gateway.bind`, `openclaw config validate --json`.

## Dependencies

- **002** supplies the Slack conditional-requirement rule enforced here.
- **003** relies on this block guaranteeing `HERMES_CRON_SCHEDULE` and `HERMES_TIMEZONE`.

## Open Questions

All three were answered before implementation. The answers are recorded here rather than in
the commit message, because two of them constrain what a later change may do.

1. **Replace the `node -e` blocks with `openclaw config set` / `patch`?** *Answered: a
   follow-up, not this change.* The gate added in task 7 already converts the D2 failure mode
   from a brick into a named startup error, which is the part that was urgent. Rewriting the
   block would touch every line 002 and 003 read the config through, in the same change that
   reorders it. Tracked as [`008`](../008-config-via-cli/SPEC.md).

2. **`ownerAllowFrom` derivation.** *Answered: `HERMES_OWNER`, with derivation as the
   fallback.* An explicit variable is the escape hatch; when it is unset the identities are
   derived from the channel allowlists, Telegram first, so no existing deployment has to add a
   variable to keep working. A channel configured with allowlist entries that cannot be owner
   identities — `*`, `accessGroup:<name>` — is the one case that demands the explicit form, and
   phase 1 says so by name.

   Two things this uncovered, both doc-verified and neither in the finding as written:

   - Entries are `<channel>:<identifier>`, not bare IDs. A bare ID cannot be routed, because
     the same number is a different account on a different channel.
   - Setting `ownerAllowFrom` alone does not satisfy the acceptance criterion. `target: 'last'`
     is documented to skip when the session has no external route, so a fresh container still
     had no heartbeat. The target is now `owner`, which resolves against `ownerAllowFrom` and
     never resolves to a group — which also closes a leak the finding did not mention: `last`
     could deliver a summary of the user's inbox into whatever group chat was most recent.

   `*` is rejected as an owner rather than passed through. It validates upstream, grants
   nothing on current builds, and strips the owner-only tools while still reading like an
   owner (upstream issues 25286 and 30226, advisory GHSA-c28g-vh7m-fm7v).

3. **Channel teardown.** *Answered: its own spec.* Removing a channel's token leaves
   `enabled: true` and a stale token in the persisted config, for both Telegram and Slack. It
   is a behaviour change rather than a correctness fix, it needs its own tests and its own
   README section, and none of this plan's eleven tasks covers it. Carried — with 002's half,
   deferred here — into [`009`](../009-channel-teardown/SPEC.md).

## Findings This Work Added

Three defects turned up while implementing, none of them in the ten rows above. All are
doc-verified against `docs.openclaw.ai`.

| ID | Claim | Anchor | Confidence | Status |
|---|---|---|---|---|
| B4d | `config.env.ANTHROPIC_API_KEY` is an unrecognised key. Upstream keeps an inline environment variable at `env.vars.<NAME>`; `env` holds `vars` and `shellEnv` and nothing else | `entrypoint.sh` first `node -e` block | doc-verified | **fixed here** — the gate in task 7 would otherwise reject the container's own config, and an upgraded volume carries the old spelling, so the legacy key is deleted as well as relocated |
| B5b | `heartbeat.target: 'last'` is documented to skip when the session has no external route, so `ownerAllowFrom` alone leaves a fresh container with no heartbeat | `entrypoint.sh` heartbeat block | doc-verified | **fixed here** — see Open Question 2 |
| D3 | `~/.openclaw/exec-approvals.json` is **retired**. Approvals live in SQLite at `~/.openclaw/state/openclaw.sqlite#exec_approvals_config`; upgrading is documented as a one-off `openclaw doctor --fix` that imports the file | `entrypoint.sh` approvals heredoc | doc-verified | **not fixed** — task 5 makes the write conditional, which is strictly better either way. Whether the container's `security: full` default takes effect at all is a separate question, tracked in [`008`](../008-config-via-cli/SPEC.md) |

### Still unverified

Four keys the entrypoint writes are absent from the published schema documentation:
`tools.exec.security`, and `tools.loopDetection`'s `warningThreshold`, `criticalThreshold` and
`globalCircuitBreakerThreshold`. They were left in place — absent from one page is weaker
evidence than documented as something else, and deleting working configuration on that basis
would be a guess — and the checks pin the list so a new hand-written key cannot be added
without someone deciding.

**If any of them is genuinely unrecognised upstream, the phase 3 gate will refuse to start a
container that previously worked.** `PLAN.md` § Risks calls for running the validator against
the current config before wiring the gate; that is not something a stub can do, and it is the
acceptance step still owed:

```bash
docker run --rm --entrypoint openclaw <image> config schema
docker exec hermes openclaw config validate --json
```
