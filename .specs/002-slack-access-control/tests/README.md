# 002 checks

Verification for [SPEC.md](../SPEC.md). No image, no credentials, no Slack workspace — the
real `entrypoint.sh` runs against a stub `openclaw` on `PATH`, and the cases read the
`openclaw.json` it writes.

```bash
.specs/002-slack-access-control/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `slack-config-test` | The accepted configurations — what lands in `openclaw.json`, and that the validator can reject. |
| `slack-validation-test` | The rejected ones — exit status *and* message, for each way of getting it wrong. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `config get`, `config validate`. |

## Why not a container

`PLAN.md` § Testing Strategy specifies container-level verification — `docker exec hermes
openclaw config get …`. That needs the image, an Anthropic API key and a Slack workspace, so
it is not something a check can do on its own.

What these cases assert is the same artefact by a shorter route. The entrypoint is the thing
under test either way; only `openclaw` is replaced. Each run gets a private `HOME` and an
`env -i` environment carrying just the variables the entrypoint requires, so no persisted
config or ambient variable carries between cases.

## The stub validator

`openclaw config validate` is the check that catches a wrong key name — the failure mode
that produced finding A2d, where a Telegram-shaped `groups` key would have validated nowhere
and gated nothing. The stub therefore does not simply exit zero: it carries a transcription
of the upstream schema for `channels.slack` and rejects unknown keys, wrong enum values, a
non-object `channels` map and unknown per-entry keys, plus the documented cross-field rule
that `dmPolicy: "open"` requires `"*"` in `allowFrom`.

Two Slack-specific negatives are deliberate, because both are valid elsewhere and are
therefore the shapes an author is most likely to reach for:

- `groupAllowFrom` is valid on telegram, whatsapp, signal, imessage, msteams and matrix.
  Slack omits it, so it is rejected here.
- `allowFrom` is valid at the Slack root and omitted from the per-channel entry schema, so
  it is rejected inside `channels.<ID>`.

It does **not** reject a channel *name* used as a `channels` key, because upstream does not
either — the zod schema is `z.record(z.string(), …)` and accepts any string. That is exactly
why the entrypoint rejects names itself: upstream's behaviour is to accept the key and then
ignore it at routing time, which is silent.

Two cases drive the validator down its *rejection* path —
`should_reject_a_telegram_shaped_groups_key_when_config_validate_runs` and
`should_reject_a_key_slack_omits_when_config_validate_runs`. Without them every validate
assertion in the suite expects a zero exit, which a validator that always succeeded would
also produce, and the drift guard would be asserted rather than tested.

The transcription is a subset built from upstream's published schema and config reference.
It is a drift guard, not the real validator.

## Manual acceptance

Two acceptance criteria cannot be met from here, and both need a real workspace:

1. **A non-allowlisted user DMs the bot and no agent turn starts.** Run it, then capture
   what `openclaw logs --json` actually emits. The policy layer's values are doc-verified —
   reason `DM_POLICY_NOT_ALLOWLISTED`, detail `dmPolicy=allowlist (not allowlisted)` — but
   nothing upstream documents them being logged, at what level, or with the sender's ID
   attached, and channel-ingress diagnostics are documented as redacted. The README gives a
   grep for those strings rather than promising a line; replace it with the observed one
   once it has been seen.
2. **The real `openclaw config validate --json` exits zero** against the config a real
   container writes.

Record both in the PR.

## Red before green

Every case was run against the pre-change `entrypoint.sh` first. 19 of 28 fail there:

```bash
ENTRYPOINT=/path/to/old/entrypoint.sh .specs/002-slack-access-control/tests/slack-config-test
ENTRYPOINT=/path/to/old/entrypoint.sh .specs/002-slack-access-control/tests/slack-validation-test
```

The nine that pass against the original are regression guards rather than gaps, and it is
worth knowing which:

- `mode`, both tokens and `enabled` were already written, and must survive the change.
- `config validate` already passed on the old four-key shape — it was never an invalid
  config, only an ungated one, which is why a schema check alone would never have found A2.
- The two validator-rejection cases pass either way: they rewrite the config after the run,
  so they test the stub rather than the entrypoint. That is deliberate — see above.
- The gateway already started, and a container with no Slack token was already fine.
- No token or ID was logged, because nothing was logged at all.
- Nothing threw a `TypeError`, because the old block never dereferenced an allowlist.

The `groups`-key case is *not* among them any more. It used to pass against the original,
because `groups` was already absent — but so was everything else, and a case that asserts
only an absence passes against an entrypoint that writes no Slack config at all. It now also
asserts that the channel map was written, which the original does not do.

## Mutation-checked

A green suite proves nothing on its own, so each case was also shown to be attached to the
behaviour it names:

```bash
.specs/002-slack-access-control/tests/mutation-check
```

Seventeen mutations, one behaviour each — trimming, empty-entry filtering, the closed
`groupPolicy` default, `requireMention`, the `allowFrom` guard, the channel-ID pattern, the
DM policy, `enabled`, `mode`, the startup log line and its counts, the empty-channel-list
check, writing the config before validating the input, exiting zero on failure, and adding
Telegram's `groups: {'*': …}` alongside the `channels` map. All seventeen are caught.

Three of them were wrong before they were right, and the corrections are the useful part:

- `dm-policy-pairing` and `require-mention-false` first reported as uncaught. Both were
  anchored on a string that also appears in the Telegram block a few lines above —
  `dmPolicy: 'allowlist',` and `requireMention: true }` — so they mutated Telegram, which
  nothing here tests, and the suite was right to stay green. Both anchors now include a
  neighbouring Slack line.
- `telegram-groups-shape` reported as *caught*, which was worse. It renamed the `channels`
  shorthand property to an undefined identifier, so the block died with a `ReferenceError`
  before writing anything, and nine cases duly noticed the crash — none of them the three
  that exist for A2d, all of which passed. A mutation that crashes proves nothing about the
  shape it claims to test. It is now a pure insertion that leaves `channels` intact, and it
  is caught by exactly those three cases and no others.

## Linting

Clean under `shellcheck -x -s bash`, and clean without `-x` when `harness.sh` is among the
inputs — which is what a whole-tree lint does. The suites carry
`# shellcheck source-path=SCRIPTDIR` so `-x` resolves the `source` from any working
directory.

## Coverage

Every automatable acceptance criterion in `SPEC.md` maps to at least one case. The two that
are not automatable are listed under *Manual acceptance* above.
