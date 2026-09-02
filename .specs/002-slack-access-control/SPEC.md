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

- [ ] Given `SLACK_BOT_TOKEN` is set and `SLACK_ALLOW_FROM` is unset, when the container
      starts, then it exits non-zero with a named, actionable error before the gateway starts.
- [ ] Given `SLACK_ALLOW_FROM="U123,U456"`, when the container starts, then
      `channels.slack.dmPolicy` is `allowlist` and `allowFrom` is `["U123","U456"]`.
- [ ] Given `SLACK_ALLOW_FROM` contains surrounding whitespace, when parsed, then entries
      are trimmed — matching the Telegram block's behaviour.
- [ ] Given no `SLACK_ALLOW_CHANNELS`, when the container starts, then
      `channels.slack.groupPolicy` is `disabled` and no channel is allowlisted.
- [ ] Given `SLACK_ALLOW_CHANNELS="C123,C456"`, when the container starts, then
      `groupPolicy` is `allowlist` and each ID maps to `{enabled: true, requireMention: true}`.
- [ ] Given a channel name (`#general`) is supplied instead of an ID, when the container
      starts, then it fails with an error naming the ID-first requirement.
- [ ] Given a user not in `allowFrom` DMs the bot, when the message arrives, then no agent
      turn is started.
- [ ] Given `openclaw config validate` runs after configuration, then it exits zero.
- [ ] Given the README, then Slack access control is documented in the same shape as
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
- `infrastructure/slack-app-manifest.json` — reduce event subscriptions to the minimum that
  supports mention-gated group use and allowlisted DMs. See Open Question 2.

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
- A denied DM should be observable in `openclaw logs` — confirm during implementation and
  document the log line, so "it silently ignored me" is diagnosable.

## Dependencies

- **004** provides the early required-vars block that enforces `SLACK_ALLOW_FROM`.
  002 can land first, but its first acceptance criterion is only fully met once 004 lands —
  note this in the commit message rather than duplicating the validation logic.

## Open Questions

1. **Enterprise Grid.** Upstream notes Grid requires a team-scoped channel ID format.
   Out of scope unless the deployment targets Grid — confirm before implementing, since it
   changes the `SLACK_ALLOW_CHANNELS` parsing.
2. **Manifest scope reduction.** Dropping `message.channels` / `message.groups` from the
   manifest would cut ambient ingestion at the source, but changes the app's capabilities
   and requires reinstalling the Slack app. Recommendation: reduce the manifest and document
   the reinstall. Needs an explicit decision — it is user-visible.
3. **Token-only teardown.** Removing `SLACK_BOT_TOKEN` later leaves `enabled: true` and a
   stale token in the persisted config. Same latent issue exists for Telegram. Fold the
   teardown path into 004, or track separately?
