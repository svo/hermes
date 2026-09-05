# Feature: Channel teardown

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Deferred from [`002`](../002-slack-access-control/SPEC.md) § Open Questions 3 and
> [`004`](../004-entrypoint-startup-correctness/SPEC.md) § Open Questions 3.

## Overview

Configuring a channel is additive and removing one is not. `entrypoint.sh` writes
`channels.telegram` when `TELEGRAM_BOT_TOKEN` is set and `channels.slack` when
`SLACK_BOT_TOKEN` is set — and does nothing at all when they are absent. The config is
persisted, so an operator who removes a token from their `docker run` gets a container that
still has the channel `enabled: true`, still holding the token, and still answering.

The token is the part that matters. It stays in `openclaw.json` on the volume after the
operator believes they have removed it, so revoking access to the assistant requires knowing to
edit a file the container claims to own.

Both channels have the same defect, which is why neither 002 nor 004 fixed half of it: one
mechanism should cover both, and fixing Slack alone would leave Telegram asymmetric.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| A2g | Removing `SLACK_BOT_TOKEN` leaves `channels.slack.enabled: true` and a stale `botToken` in the persisted config | `entrypoint.sh` Slack block | internal-contradiction |
| B3d | Removing `TELEGRAM_BOT_TOKEN` leaves `channels.telegram.enabled: true` and a stale `botToken` in the persisted config | `entrypoint.sh` Telegram block | internal-contradiction |

## User Stories

- As the operator, I want removing a channel's token from `docker run` to actually remove the
  channel, so that revoking access does not require editing a file by hand.
- As the operator, I want a token I have removed to stop being stored, so that a copy of the
  volume does not carry a credential I thought was gone.

## Acceptance Criteria

- [ ] Given a container configured with a channel token, when it restarts without that token,
      then the channel is disabled in the persisted config.
- [ ] Given the same restart, then the channel's token is no longer present anywhere in
      `openclaw.json`.
- [ ] Given the same restart, then the other channel's configuration is untouched.
- [ ] Given a restart with the token still set, then nothing is torn down.
- [ ] Given a container that never had the channel configured, when it starts, then no empty
      channel block is written.
- [ ] Given a teardown happens, then the container logs one line saying which channel was
      disabled — the operator should not have to diff a config file to find out.

## Structural Impact

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
A new block covering both channels, sequenced after both channel blocks and before 004's
phase 3 gate. Neither existing channel block changes, so 002's region and the Telegram block
are untouched.

### Documentation
`README.md` — both Access control sections gain a sentence on what removing the token does.

## Dependencies

- **004** supplies the phase ordering and the `openclaw config validate` gate a teardown has to
  leave a valid config for.

## Open Questions

1. **Disable, or delete the whole block?** Deleting is cleaner and loses the allowlist, so
   re-adding the token means re-supplying `SLACK_ALLOW_FROM`. Disabling keeps the allowlist and
   leaves a disabled block in the file. Deleting is the honest reading of "remove the channel";
   disabling is kinder to an operator who is only rotating a token.
2. **Does teardown belong in the entrypoint at all?** It makes the config a function of the
   environment, which is this image's model — but it also means a `docker run` that forgets a
   `-e` silently disables a channel rather than leaving it alone. A `HERMES_CHANNEL_TEARDOWN`
   opt-out would keep both, at the cost of another variable.
