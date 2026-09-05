# Feature: Slack access control

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

The Telegram channel block sets `dmPolicy: 'allowlist'`, an `allowFrom` list, and
`groups: {'*': {requireMention: true}}`. The Slack block sets `enabled`, `mode`, `botToken`,
`appToken` — and nothing else. There is no DM policy, no allowlist, and no mention gate.

Any member of the workspace who can DM the bot drives an agent with an unrestricted root
shell and a domain-wide-delegated Google Workspace credential. The supplied app manifest
compounds it: `message.channels` and `message.groups` are subscribed, so the bot ingests
every message in every channel it joins, all of it flowing into the agent that 001 is
fencing.

This spec brings Slack to parity with Telegram, using Slack's own configuration shape.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| A2a | Slack block sets no `dmPolicy`, `allowFrom`, or mention gate | `entrypoint.sh:254-259` | internal-contradiction |
| A2b | Telegram has all three; the asymmetry is unintentional | `entrypoint.sh:237-243` | internal-contradiction |
| A2c | `channels.slack.dmPolicy` is a supported key | upstream emergency-rollback config | doc-verified |
| A2d | Slack uses `groupPolicy` + `channels: {<ID>: …}`, **not** Telegram's `groups: {'*': …}` | upstream `docs/channels/slack.md` | doc-verified |
| A2e | Slack channel allowlists are **ID-first**; `#name` keys are ignored and blocked under allowlist mode | upstream `docs/channels/ambient-room-events.md` | doc-verified |
| A2f | Manifest subscribes to all channel and group messages | `slack-app-manifest.json:47-49` | internal-contradiction |
| A2g | README documents no Slack access control | `README.md:109-130` | internal-contradiction |

## User Stories

- As the operator, I want only named Slack users to DM the assistant, so that workspace
  membership alone does not grant a root shell.
- As the operator, I want group replies gated behind an explicit mention, so that the agent
  does not act on ambient channel chatter.
- As the operator, I want Slack configured the same way as Telegram, so that I do not have
  to remember which channel is the permissive one.
- As a new user following the README, I want the secure configuration to be the documented
  default, so that I do not have to discover the gap myself.

## Acceptance Criteria

- [x] Given `SLACK_BOT_TOKEN` is set and `SLACK_ALLOW_FROM` is unset, when the container
      starts, then it exits non-zero with a named, actionable error before the gateway starts.
- [x] Given `SLACK_ALLOW_FROM="U123,U456"`, when the container starts, then
      `channels.slack.dmPolicy` is `allowlist` and `allowFrom` is `["U123","U456"]`.
- [x] Given `SLACK_ALLOW_FROM` contains surrounding whitespace, when parsed, then entries
      are trimmed — matching the Telegram block's behaviour.
- [x] Given no `SLACK_ALLOW_CHANNELS`, when the container starts, then
      `channels.slack.groupPolicy` is `disabled` and no channel is allowlisted.
- [x] Given `SLACK_ALLOW_CHANNELS="C123,C456"`, when the container starts, then
      `groupPolicy` is `allowlist` and each ID maps to `{enabled: true, requireMention: true}`.
- [x] Given a channel name (`#general`) is supplied instead of an ID, when the container
      starts, then it fails with an error naming the ID-first requirement.
- [ ] Given a user not in `allowFrom` DMs the bot, when the message arrives, then no agent
      turn is started. — **manual**: needs a real workspace. See `tests/README.md`
      § Manual acceptance.
- [x] Given `openclaw config validate` runs after configuration, then it exits zero.
      Automated against a transcription of the upstream schema; the real validator is part
      of the same manual step.
- [x] Given the README, then Slack access control is documented in the same shape as
      Telegram's, including how to obtain user and channel IDs.

## Structural Impact

### Provisioning
No change.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
- Slack block (`:248-262`) — owned region. Adds `dmPolicy`, `allowFrom`, `groupPolicy`, and
  a `channels` map.
- The required-vars validation added by **004** is where `SLACK_ALLOW_FROM`'s conditional
  requirement is enforced. This spec supplies the rule; 004 supplies the mechanism.

### Agent pipeline
No change.

### Agent instructions
No change.

### Image & CI
- `infrastructure/slack-app-manifest.json` — **unchanged.** The reduction this section
  proposed does not survive contact with upstream's defaults: it would break the very
  mention-gated group use it was required to preserve. See Open Question 2 for the evidence
  and for the order a later reduction has to follow.

### Documentation
- `README.md:109-130` — new `SLACK_ALLOW_FROM` / `SLACK_ALLOW_CHANNELS` rows in the
  environment table, and setup steps for retrieving Slack IDs.

## Configuration Contract

| Variable | Required | Maps to |
|---|---|---|
| `SLACK_BOT_TOKEN` | No (gates the block) | `channels.slack.botToken` |
| `SLACK_APP_TOKEN` | With `SLACK_BOT_TOKEN` | `channels.slack.appToken` |
| `SLACK_ALLOW_FROM` | **With `SLACK_BOT_TOKEN`** | `channels.slack.allowFrom` (+ `dmPolicy: allowlist`) |
| `SLACK_ALLOW_CHANNELS` | No | `channels.slack.channels` keyed by ID (+ `groupPolicy: allowlist`) |

Default when `SLACK_ALLOW_CHANNELS` is absent: `groupPolicy: "disabled"`. Closed by default;
opening group access is an explicit act.

`allowFrom` entries may also take the documented `accessGroup:<name>` form. Pass-through
without parsing; do not reject entries containing `:`.

## Operability

- Startup logs one line per configured channel: policy and entry count, never token values.
- Verifiable without reading the config file:
  `docker exec hermes openclaw config get channels.slack.dmPolicy` → `allowlist`.
- A denied DM should be observable in `openclaw logs` — **partially answered.** The policy
  layer's decision values are doc-verified: reason `DM_POLICY_NOT_ALLOWLISTED`, detail
  `dmPolicy=allowlist (not allowlisted)`. Whether they are emitted as a log record, at what
  level, and whether the sender's ID survives is *not* documented, and channel-ingress
  diagnostics are documented as redacted. The README therefore gives a grep for those
  strings and a config-first check, and does not promise a literal line. Capturing the real
  one is part of the manual acceptance step.

## Dependencies

- **004** provides the early required-vars block that enforces `SLACK_ALLOW_FROM`.
  002 can land first, but its first acceptance criterion is only fully met once 004 lands —
  note this in the commit message rather than duplicating the validation logic.

## Open Questions

All three were answered before implementation. The answers are recorded here rather than in
the commit message, because two of them constrain what a later change may do.

1. **Enterprise Grid.** *Answered: standard workspaces only.* `SLACK_ALLOW_CHANNELS` entries
   are validated against `/^[CG][A-Z0-9]+$/`. Grid's team-scoped form,
   `team:<team-id>:channel:<channel-id>` (doc-verified), is rejected by that pattern and
   fails at startup with the ID-first error rather than being accepted and then ignored — so
   a Grid deployment learns it in the first second rather than from a silent non-response.
   Widening the pattern is the whole change if Grid is ever in scope.

2. **Manifest scope reduction.** *Answered: do not reduce it — not in the shape this spec
   proposed.* The recommendation was checked against upstream first, and it does not hold:

   - **Dropping `message.channels` / `message.groups` breaks mention-gated group use**,
     which is the thing § Image & CI said the reduction had to preserve. OpenClaw's mention
     gate also fires on user-group mentions, regex patterns, replies to the bot's own
     messages, and follow-up messages in a thread it is already in — none of which produce
     an `app_mention` event. Every manifest upstream publishes (Recommended, Minimal,
     Enterprise Grid, HTTP) pairs `app_mention` **with** both message events; there is no
     shipped variant without them. The practical effect of the trim would be that the bot
     answers the first mention in a thread and then goes silent.
   - **Dropping `pins:write`, `reactions:write` and `files:write` breaks default-on
     behaviour.** `channels.slack.actions` defaults to all five groups enabled — messages,
     reactions, pins, memberInfo, emojiList — and `messages.ackReactionScope` defaults to
     `group-mentions`, so the gateway acknowledges every mention in an allowlisted channel
     with a `reactions.add`. This deployment sets none of those keys, so it gets the
     defaults. Removing the scopes turns default behaviour into `missing_scope` errors in
     exactly the channels the operator just allowlisted.

   A2f therefore stands as written — the bot does ingest every message in every channel it
   has joined — but it is now mitigated at the policy layer instead: `groupPolicy` is
   `disabled` unless channels are explicitly listed, so nothing ambient reaches an agent
   turn. Cutting it at the source remains worth doing, and needs its own spec, because the
   safe order is config first, manifest second: gate the action groups in
   `channels.slack.actions`, deploy that, verify on a test workspace, and only then reinstall
   the app with the smaller scope set. That is agent-capability work, not access control.

3. **Token-only teardown.** *Answered: 004 owns it — and 004 has since deferred it again, to
   [`009`](../009-channel-teardown/SPEC.md), carrying both channels' halves.* It is already 004's Open Question 3,
   and it is one mechanism covering both channels — Slack alone would leave Telegram
   asymmetric, which is the class of gap this spec exists to remove.
