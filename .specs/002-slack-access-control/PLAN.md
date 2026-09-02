# Plan: Slack access control

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

Extend the existing Slack `node -e` block in place. Do not restructure it — 004 owns the
entrypoint's ordering and 003 owns the block below it; a structural rewrite here would
collide with both.

The important detail is that **Slack's config shape is not Telegram's**. Copying the
Telegram block would produce a config that looks correct and silently does nothing:

| | Telegram | Slack |
|---|---|---|
| DM gate | `dmPolicy` + `allowFrom` | `dmPolicy` + `allowFrom` |
| Group gate | `groups: {'*': {requireMention: true}}` | `groupPolicy` + `channels: {<ID>: {enabled, requireMention}}` |
| Group key | wildcard `'*'` supported | **channel ID only** — `#name` is ignored and blocked under allowlist |

Default posture is closed: `groupPolicy: "disabled"` unless `SLACK_ALLOW_CHANNELS` is
supplied. This is a deliberate difference from Telegram's wildcard-with-mention default,
because Slack has no wildcard and an empty allowlist under `groupPolicy: "allowlist"` would
be an easy-to-misread way of saying the same thing.

Fail fast on channel **names**. A `#general` in `SLACK_ALLOW_CHANNELS` is silently ignored
by upstream — exactly the silent-no-op class this programme exists to remove — so reject it
at startup with a message that names the requirement.

## Layer Changes

### Provisioning
None.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned region: `:248-262`.

- Extend `config.channels.slack` with:
  - `dmPolicy: 'allowlist'`
  - `allowFrom: process.env.SLACK_ALLOW_FROM.split(',').map(s => s.trim()).filter(Boolean)`
  - `groupPolicy` — `'allowlist'` when `SLACK_ALLOW_CHANNELS` is set, else `'disabled'`
  - `channels` — each ID mapped to `{ enabled: true, requireMention: true }`
- Validate every `SLACK_ALLOW_CHANNELS` entry against `/^[CG][A-Z0-9]+$/` and exit non-zero
  with a named error otherwise.
- Guard `SLACK_ALLOW_FROM` before dereferencing it. **Do not** reproduce the Telegram bug at
  `:241` (`process.env.TELEGRAM_ALLOW_FROM.split` on `undefined` → `TypeError`); 004 fixes
  that one, and this block must not add a second instance.

### Agent pipeline / instructions
None.

### Image & CI
- `infrastructure/slack-app-manifest.json` — pending Open Question 2, reduce `bot_events`
  and trim unused write scopes (`pins:write`, `reactions:write`, `files:write`) to match
  actual usage.

### Documentation
- `README.md` environment table — add `SLACK_ALLOW_FROM` (required with `SLACK_BOT_TOKEN`)
  and `SLACK_ALLOW_CHANNELS` (optional).
- `README.md:109-130` — add a step for retrieving a Slack user ID (profile → More → Copy
  member ID) and a channel ID (channel details → bottom of the About tab), and state that
  group access is disabled unless channels are listed.
- Update the Slack `docker run` example to include `SLACK_ALLOW_FROM`.

## Configuration Contract

| In | Out |
|---|---|
| `SLACK_ALLOW_FROM` (required with `SLACK_BOT_TOKEN`) | `channels.slack.dmPolicy = "allowlist"`, `channels.slack.allowFrom = [...]` |
| `SLACK_ALLOW_CHANNELS` (optional) | `channels.slack.groupPolicy`, `channels.slack.channels` |
| absent `SLACK_ALLOW_CHANNELS` | `channels.slack.groupPolicy = "disabled"` |

`accessGroup:<name>` entries in `SLACK_ALLOW_FROM` pass through untouched.

## Task List

1. [ ] runtime-config: add `SLACK_ALLOW_FROM` parsing with `dmPolicy: 'allowlist'`,
       trimmed and filtered, guarded against undefined.
2. [ ] runtime-config: add `SLACK_ALLOW_CHANNELS` parsing, ID-format validation with a
       named error, `groupPolicy`, and the `channels` map.
3. [ ] runtime-config: default `groupPolicy` to `'disabled'` when no channels are supplied.
4. [ ] tests: container smoke matrix — token without allowlist (expect non-zero exit and the
       named error), token with allowlist (expect the four config keys), channel name
       supplied (expect the ID-first error).
5. [ ] tests: assert `openclaw config validate` exits zero after each successful case.
6. [ ] docs: README environment table, ID-retrieval steps, updated `docker run` example.
7. [ ] manifest: reduce `bot_events` and write scopes — **only after** Open Question 2 is
       answered, since it requires reinstalling the Slack app.

## Testing Strategy

No test framework exists. Verification is container-level and config-level:

- `bash -n` and `shellcheck` on `entrypoint.sh` after each task.
- **Config assertions** — run the container with a fixture env, then:
  ```
  docker exec hermes openclaw config get channels.slack.dmPolicy    # allowlist
  docker exec hermes openclaw config get channels.slack.groupPolicy # disabled | allowlist
  jq '.channels.slack.allowFrom' /opt/hermes/data/openclaw.json     # ["U123","U456"]
  ```
- **Schema assertion** — `openclaw config validate --json` exits zero. This is the check that
  catches a wrong key name, which is the failure mode that produced A2d.
- **Negative cases** are the point of this spec: the token-without-allowlist and
  channel-name cases must both fail loudly. Assert the exit code *and* the message.
- Naming: `should_<behaviour>_when_<condition>`.

Live end-to-end DM denial (a non-allowlisted user messaging the bot) needs a real workspace
and is a manual acceptance step, not automated. Record the result in the PR.

## Operability Plan

- One startup log line per channel: `slack: dmPolicy=allowlist allowFrom=2 groupPolicy=disabled`.
  Counts only — never token values, never the IDs themselves.
- Document the log line emitted when a DM is denied, so a locked-out user is diagnosable
  rather than mysterious.

## Risks and Mitigations

- **Risk:** copying Telegram's `groups: {'*': …}` shape into Slack produces a config that
  validates but does not gate. → **Mitigation:** the shape table above; task 5's schema
  assertion; an explicit test that `groups` does **not** appear under `channels.slack`.
- **Risk:** making `SLACK_ALLOW_FROM` mandatory breaks an existing deployment on upgrade.
  → **Mitigation:** the error names the variable and the fix. Call it out in the release
  note — this is a deliberate breaking change and should not be silent.
- **Risk:** `#channel-name` entries are silently ignored upstream, so a misconfigured
  allowlist reads as "the bot ignores my channel". → **Mitigation:** reject names at startup
  with a message naming the ID-first requirement.
- **Risk:** manifest changes require an app reinstall and can interrupt a working
  deployment. → **Mitigation:** task 7 is sequenced last and gated on an explicit decision.
- **Risk:** IDs are logged and leak workspace membership. → **Mitigation:** log counts only.
