<p align="center">
  <img src="icon.png" alt="Hermes" width="128">
</p>

# Hermes

[![Build Development](https://github.com/svo/hermes/actions/workflows/development.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/development.yml)
[![Build Builder](https://github.com/svo/hermes/actions/workflows/builder.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/builder.yml)
[![Build Service](https://github.com/svo/hermes/actions/workflows/service.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/service.yml)

Docker image running an [OpenClaw](https://docs.openclaw.ai) gateway with [gog](https://github.com/steipete/gog) (Google Suite CLI) for Gmail, Calendar, Drive, and Contacts access.

## Prerequisites

* `vagrant`
* `ansible`
* `colima`
* `docker`
- An Anthropic API key

## Building

```bash
# Build for a specific architecture
./build.sh service arm64
./build.sh service amd64

# Push
./push.sh service arm64
./push.sh service amd64

# Create and push multi-arch manifest
./create-latest.sh service
```

## Running

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  --pull always \
  -e ANTHROPIC_API_KEY="your-api-key" \
  -e TELEGRAM_BOT_TOKEN="your-telegram-bot-token" \
  -e GOG_GOOGLE_ACCOUNT="you@yourdomain.com" \
  -e GOG_SERVICE_ACCOUNT_KEY="/root/.openclaw/service-account.json" \
  -e HERMES_VIBE="calm, direct, efficient" \
  -e HERMES_TONE="casual but competent — like a trusted colleague, not a customer service rep" \
  -e HERMES_USER_NAME="SVO" \
  -e HERMES_TIMEZONE="Australia/Melbourne" \
  -e HERMES_LOCALE="en-AU" \
  -e HERMES_CRON_SCHEDULE="0 8 * * *" \
  -e HERMES_QUIET_HOURS_START="20:00" \
  -e HERMES_QUIET_HOURS_END="08:00" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

On first run, the entrypoint automatically configures OpenClaw via non-interactive onboarding and sets up Telegram and Google Suite access. Configuration is persisted to the volume at `/root/.openclaw` so subsequent starts skip onboarding.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes, every start | Anthropic API key for the OpenClaw gateway. Required on **every** start, not only the first — see [Startup validation](#startup-validation) |
| `GOG_GOOGLE_ACCOUNT` | No | Google account email for gog service account auth |
| `GOG_SERVICE_ACCOUNT_KEY` | No | Path (inside the container) to the GCP service account JSON key file |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token from @BotFather |
| `TELEGRAM_ALLOW_FROM` | With `TELEGRAM_BOT_TOKEN` | Comma-separated Telegram user IDs to allow. The container refuses to start without it |
| `SLACK_BOT_TOKEN` | No | Slack bot token (`xoxb-...`) from the Slack app settings |
| `SLACK_APP_TOKEN` | With `SLACK_BOT_TOKEN` | Slack app-level token (`xapp-...`) with `connections:write` scope |
| `SLACK_ALLOW_FROM` | With `SLACK_BOT_TOKEN` | Comma-separated Slack user IDs allowed to DM the assistant |
| `SLACK_ALLOW_CHANNELS` | No | Comma-separated Slack channel IDs the assistant may answer in; group access is disabled when unset |
| `HERMES_VIBE` | Yes | Personality vibe descriptors |
| `HERMES_TONE` | Yes | Communication tone descriptors |
| `HERMES_USER_NAME` | Yes | User's name |
| `HERMES_TIMEZONE` | Yes | Timezone for scheduling |
| `HERMES_LOCALE` | Yes | Spelling and language conventions |
| `HERMES_CRON_SCHEDULE` | Yes | Cron expression for morning briefing |
| `HERMES_QUIET_HOURS_START` | Yes | Quiet hours start time (e.g. `20:00`) |
| `HERMES_QUIET_HOURS_END` | Yes | Quiet hours end time (e.g. `08:00`) |
| `HERMES_OWNER` | Sometimes | Who the heartbeat reports to, as comma-separated `<channel>:<id>` identities (e.g. `telegram:123456789`, `slack:U0123ABCDE`). Derived from the channel allowlists when unset; required when a channel is configured and none of its entries can serve as an owner — see [Heartbeat delivery](#heartbeat-delivery) |
| `HERMES_FIELD_MAX_LEN` | No | Maximum length of an untrusted email or calendar field in `hermes-check` output (default `200`) |
| `HERMES_BRIEFING_CHANNEL` | With `HERMES_BRIEFING_TO` | Channel the morning briefing is announced to (e.g. `slack`, `telegram`). Without it the briefing relies on implicit routing |
| `HERMES_BRIEFING_TO` | With `HERMES_BRIEFING_CHANNEL` | Where in that channel to announce it. The format is channel-specific — Slack takes `channel:C0123ABCDE`, Telegram a bare chat id such as `-1001234567890` |
| `HERMES_CRON_READY_ATTEMPTS` | No | How many times to poll for gateway readiness before giving up on registering the briefing (default `60`, two seconds apart) |
| `HERMES_CRON_REGISTER_ATTEMPTS` | No | How many registration attempts before giving up (default `5`, three seconds apart) |
| `HERMES_CRON_CALL_TIMEOUT` | No | Seconds any single `openclaw` call the registrar makes may take before it is abandoned (default `30`; a create gets twice that) |

## Telegram Integration

Connect Hermes to Telegram so you can chat with your assistant directly from the Telegram app.

### Setup

1. Open Telegram and start a chat with [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to name your bot
3. Save the bot token that BotFather returns
4. Pass it as an environment variable when running the container:

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -e ANTHROPIC_API_KEY="your-api-key" \
  -e TELEGRAM_BOT_TOKEN="your-telegram-bot-token" \
  -e TELEGRAM_ALLOW_FROM="your-telegram-user-id" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

On startup, the entrypoint automatically configures the Telegram channel in OpenClaw with group
chats set to require `@mention`. The DM policy is always `allowlist` — only the listed Telegram
user IDs can message the bot.

### Access control

`TELEGRAM_ALLOW_FROM` is **required** whenever `TELEGRAM_BOT_TOKEN` is set, and the container
refuses to start without it. There is no fallback policy: `dmPolicy` is written as `allowlist`
unconditionally, so an absent allowlist would be an allowlist admitting nobody.

| Config key | Value |
|---|---|
| `channels.telegram.dmPolicy` | `allowlist` — only `TELEGRAM_ALLOW_FROM` may DM the assistant |
| `channels.telegram.allowFrom` | the trimmed, comma-separated contents of `TELEGRAM_ALLOW_FROM` |
| `channels.telegram.groups` | `{"*": {"requireMention": true}}` — any group, mention-gated |

To find your Telegram user ID, message a bot such as [@userinfobot](https://t.me/userinfobot),
which replies with your numeric ID. Earlier versions of this document said to message *your* bot
with `TELEGRAM_ALLOW_FROM` unset and read the ID off a pairing prompt. That never worked: this
image does not configure `pairing`, and starting without the allowlist crashed the entrypoint
before the gateway came up.

## Slack Integration

Connect Hermes to Slack so you can chat with your assistant from any Slack workspace.

### Setup

1. Create a Slack app at https://api.slack.com/apps using the manifest in [`infrastructure/slack-app-manifest.json`](infrastructure/slack-app-manifest.json) — this configures Socket Mode, bot scopes, and event subscriptions automatically
2. Go to Basic Information > App-Level Tokens > generate a token with `connections:write` scope — this is your `SLACK_APP_TOKEN` (`xapp-...`)
3. Install the app to the workspace and go to OAuth & Permissions to copy the Bot User OAuth Token — this is your `SLACK_BOT_TOKEN` (`xoxb-...`)
4. Collect the **user IDs** allowed to DM the assistant — this is your `SLACK_ALLOW_FROM`. In Slack, click the person, then **More**, then **Copy member ID**. It looks like `U0123ABCDE`
5. Optionally collect the **channel IDs** the assistant may answer in — this is your `SLACK_ALLOW_CHANNELS`. Open the channel, click its name, and read the **Channel ID** at the bottom of the **About** tab. It looks like `C0123ABCDE`, or `G0123ABCDE` for a private channel. Group access stays disabled unless you list channels here
6. Pass the tokens and the allowlist as environment variables:

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -e ANTHROPIC_API_KEY="your-api-key" \
  -e SLACK_BOT_TOKEN="xoxb-your-slack-bot-token" \
  -e SLACK_APP_TOKEN="xapp-your-slack-app-token" \
  -e SLACK_ALLOW_FROM="U0123ABCDE" \
  -e SLACK_ALLOW_CHANNELS="C0123ABCDE" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

### Access control

`SLACK_ALLOW_FROM` is **required** whenever `SLACK_BOT_TOKEN` is set, and the container
refuses to start without it. Workspace membership is not authorisation: every DM starts an
agent turn holding an unrestricted shell and, where configured, a domain-wide delegated
Google Workspace credential.

| Config key | Value |
|---|---|
| `channels.slack.dmPolicy` | `allowlist` — only `SLACK_ALLOW_FROM` may DM the assistant |
| `channels.slack.allowFrom` | the trimmed, comma-separated contents of `SLACK_ALLOW_FROM` |
| `channels.slack.groupPolicy` | `disabled`, or `allowlist` when `SLACK_ALLOW_CHANNELS` is set |
| `channels.slack.channels` | each listed ID mapped to `{enabled: true, requireMention: true}` |

Slack's shape is not Telegram's. DMs gate the same way, but group access gates on
`groupPolicy` and a `channels` map keyed by channel ID; there is no wildcard, and `groups` is
not a Slack key at all — `openclaw config validate` rejects it as unrecognised. Group access
is therefore closed by default rather than mention-gated by default: opening it is an
explicit act.

`*` is OpenClaw's spelling of *everyone*. An `allowFrom` containing it admits the whole
workspace while `dmPolicy` still reads `allowlist` and the startup line still reports a
count, so nothing on the operator-facing surface will look unusual. It is a valid upstream
configuration and is passed through unchanged — do not put it in `SLACK_ALLOW_FROM` unless
opening the assistant to every workspace member is what you mean.

Channel allowlists are **ID-first**. OpenClaw's router ignores a channel *name*, so a
`#general` in `SLACK_ALLOW_CHANNELS` would leave the bot silently unresponsive there. The
container rejects names at startup instead, naming the requirement. Enterprise Grid's
team-scoped form (`team:T…:channel:C…`) is out of scope and is rejected the same way.

Entries in `SLACK_ALLOW_FROM` may also take OpenClaw's `accessGroup:<name>` form; they are
passed through unparsed.

The app manifest still subscribes to `message.channels` and `message.groups`, so the bot
receives every message in every channel it has joined. `groupPolicy` is what stops the agent
acting on them. Narrowing the subscription is not as simple as deleting those two events —
see [`.specs/002-slack-access-control/SPEC.md`](.specs/002-slack-access-control/SPEC.md)
§ Open Questions.

On startup the container logs one line for the channel — policies and counts only, never
tokens and never the IDs themselves:

```
slack: dmPolicy=allowlist allowFrom=2 groupPolicy=allowlist channels=1
```

Verify without reading the config file:

```bash
docker exec hermes openclaw config get channels.slack.dmPolicy    # allowlist
docker exec hermes openclaw config get channels.slack.groupPolicy # disabled | allowlist
```

### When a DM is ignored

Denial is by omission — OpenClaw has no denylist — so a sender who is not in `allowFrom` is
blocked with nothing said in the Slack conversation. Check the configuration first:

```bash
docker exec hermes openclaw config get channels.slack.allowFrom
```

If the sender's ID is not in that list, that is the answer. To see the decision in the
gateway log:

```bash
docker exec hermes openclaw logs --limit 500 --plain | grep -Ei 'dmPolicy=|DM_POLICY_'
```

The policy layer produces the reason `DM_POLICY_NOT_ALLOWLISTED` alongside the detail
`dmPolicy=allowlist (not allowlisted)`. Those are the strings to grep for. The exact log
line, its level, and whether the sender's ID appears in it are not documented upstream, and
channel-ingress diagnostics are documented as redacted — so do not expect to find your own
`U…` ID there. If nothing appears, raise the level with
`openclaw config set logging.level trace` and reproduce.

## Google Calendar/Email Integration

The image includes [gog](https://github.com/steipete/gog), a CLI for Google Suite (Gmail, Calendar, Drive, Contacts). Two authentication methods are supported:

### Option A: Service Account (Google Workspace, fully automated)

#### GCP Setup

1. Create a GCP project (or use an existing one)
2. Enable the following APIs (APIs & Services > Enable APIs):
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - People API (Contacts)
3. Create a service account (IAM & Admin > Service Accounts)
4. Enable domain-wide delegation on the service account:
   - Click into the service account > Details > Advanced settings
   - Check "Enable Google Workspace Domain-wide Delegation"
5. Create a JSON key (Keys tab > Add key > Create new key > JSON)
6. Place the downloaded key file in the data volume (e.g., `/opt/hermes/data/service-account.json`)

#### Google Workspace Admin Console

1. Go to Security > API controls > Domain-wide delegation
2. Click "Add new" to add an API client
3. Enter the service account's **Client ID** (found in GCP under the service account details)
4. Add the required OAuth scopes (comma-separated):
   ```
   https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/gmail.settings.basic,https://www.googleapis.com/auth/gmail.settings.sharing,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/contacts,https://www.googleapis.com/auth/contacts.other.readonly,https://www.googleapis.com/auth/directory.readonly
   ```
#### Run the container

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -e ANTHROPIC_API_KEY="your-api-key" \
  -e GOG_GOOGLE_ACCOUNT="you@yourdomain.com" \
  -e GOG_SERVICE_ACCOUNT_KEY="/root/.openclaw/service-account.json" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

### Option B: OAuth (personal Gmail, one-time interactive setup)

1. Create a GCP project with a "Desktop app" OAuth client
2. Download the `client_secret.json` file
3. Run the auth commands interactively inside the container:

```bash
docker exec -it hermes bash
gog auth credentials /root/.openclaw/client_secret.json
gog auth add you@gmail.com
```

Tokens are persisted in the volume so this only needs to be done once.

## Workspace Instructions

On startup, the entrypoint generates OpenClaw workspace files at `~/.openclaw/workspace/` using the `HERMES_*` environment variables and sets `agents.defaults.skipBootstrap: true` so OpenClaw uses the pre-seeded files directly:

| File | Content |
|---|---|
| `IDENTITY.md` | Name, vibe, and emoji |
| `SOUL.md` | Persona, tone, and boundaries |
| `AGENTS.md` | Operating instructions — role, capabilities, monitoring, and document workflows |
| `USER.md` | User name, timezone, and locale |

These files are injected into the agent's context at the start of every session, so Hermes has detailed operating guidance available immediately without needing an initial brief.

Every `HERMES_*` variable marked required in the table above must be set. This makes the
configuration explicit and avoids hidden assumptions about identity, tone, or scheduling.

## Startup validation

The container validates its whole environment **before it writes anything**. Onboarding, the
Google credential, and every key of `openclaw.json` come after that check, so a misconfigured
start leaves the config volume exactly as it found it.

```
Phase 1  validate    no writes, no network, no side effects
Phase 2  configure   onboarding, credentials, config
Phase 3  verify      openclaw config validate, then the gateway
```

A rejected start prints one block listing **every** missing variable, not the first one:

```
Error: missing required environment variables:
  HERMES_LOCALE
  TELEGRAM_ALLOW_FROM

TELEGRAM_ALLOW_FROM is required when TELEGRAM_BOT_TOKEN is set.
  ...

Nothing has been written. The persisted configuration is untouched.
```

A three-variable misconfiguration is one restart, not three.

### `ANTHROPIC_API_KEY` is required on every start

This is a **behaviour change**, and it will stop a container that used to start.

The persisted config keeps a copy of the key. A restart without the variable used to overwrite
that copy with nothing and then exit **zero** — so the key configured once was silently deleted,
and the start after that came up unauthenticated with no failure anywhere to explain it. The
key is now a required variable, which means the config file is never opened when it is absent.

If you have been relying on the key already being in the volume, add `-e ANTHROPIC_API_KEY=…`
to your `docker run` before upgrading.

### The configuration is validated against the schema

After the config is written and before the gateway starts, the entrypoint runs `openclaw config
validate`. Roughly fifteen keys are written into strict schemas by hand; without this gate an
upstream key rename turned a working image into one that bricked on the next restart with
nothing useful in the log. A failure now costs one startup and names the key path:

```
Error: the configuration this container just wrote is not valid.
  openclaw config validate said:
    agents.defaults.heartbeat.bogusKey: unrecognised key

  The gateway was not started, because it would fail to load this.
  Compare the key it names against: openclaw config schema
```

A successful start logs one line:

```
config: validated
```

Verify by hand at any time:

```bash
docker exec hermes openclaw config validate --json
docker exec hermes openclaw config get commands.ownerAllowFrom
```

### Exec approvals are yours after the first start

`~/.openclaw/exec-approvals.json` is written only when it is absent. It used to be rewritten on
every start, so an operator who tightened `defaults.security` had it reverted to `full` by the
next restart — a restart quietly widening what the agent may run.

The cost is that a change to the shipped default no longer reaches an existing container. To
adopt one, delete the file and restart:

```bash
docker exec hermes rm /root/.openclaw/exec-approvals.json && docker restart hermes
```

## Heartbeat delivery

The heartbeat summarises the user's inbox and calendar, so where it delivers matters.

It targets `owner`, which resolves against `commands.ownerAllowFrom`. That key is derived from
the channel allowlists — Telegram first, then Slack — as `<channel>:<id>` identities, or set
explicitly with `HERMES_OWNER`:

```bash
  -e HERMES_OWNER="telegram:123456789"
```

Set it explicitly when the allowlist holds more people than the operator, or when nothing in the
allowlist can be an owner. Two entries cannot: `*`, which is a policy rather than an account, and
`accessGroup:<name>`, which names a group. Both stay valid in `TELEGRAM_ALLOW_FROM` and
`SLACK_ALLOW_FROM`; they just cannot also answer who the owner is, and the container says so at
startup rather than going quiet later.

Previously the target was `last`, the most recent external conversation. On a fresh container
there is none, so every heartbeat was skipped — and once there was one, it could be a group
chat, which is not where a summary of the user's inbox belongs.

## Morning Briefing

At `HERMES_CRON_SCHEDULE`, in `HERMES_TIMEZONE`, Hermes runs `hermes-check`, reads the day's
calendar and the overnight inbox, and sends one combined briefing.

It is an OpenClaw **automation**, registered through the CLI. Cron data lives in the
gateway's own store, so there is nothing hand-editable to inspect — use the CLI:

```bash
docker exec hermes openclaw cron list --all
```

Exactly one job named `morning-briefing` should be listed. `--all` matters: without it the
listing shows only *enabled* jobs, so a briefing someone disabled reads as missing and sends
you looking for a registration failure that never happened. The registrar passes `--all` for
the same reason — otherwise it would register a second copy alongside the disabled one. Take its id and you can trigger it
on demand, or read what happened the last few times it fired:

```bash
docker exec hermes openclaw cron run <jobId>
docker exec hermes openclaw cron runs --id <jobId> --limit 50
```

(`openclaw cron` is an alias for `openclaw automations`; either spelling works.)

### Registration happens after the gateway starts

Automation mutations are served by the gateway scheduler and require the `operator.admin`
permission, so the briefing cannot be registered before the gateway is up. The entrypoint
forks a registrar just before `exec`ing the gateway: it waits for readiness, checks whether
the job already exists, creates it if it does not, logs the outcome, and exits. The gateway
remains PID 1.

Registration is asymmetric on purpose. **A failure to register never stops the gateway** —
chat access matters more than the briefing, and a container that refuses to start because a
briefing could not be scheduled helps nobody. So the failure has to be visible instead:

```bash
docker logs hermes | grep '^cron:'
```

| Line | Meaning |
|---|---|
| `cron: waiting for gateway (up to <n> attempts)` | The registrar is up, polling for readiness |
| `cron: registered morning-briefing <id>` | Created on this start |
| `cron: morning-briefing already registered (<id>)` | Found; nothing was created |
| `cron: registration attempt <n>/<max> failed: <error>` | One attempt failed; the underlying message follows |
| `cron: giving up after <n> attempts; briefing not scheduled (<why>)` | Bounded retries exhausted; **there is no briefing** |

All three budgets must be positive whole numbers. The container refuses to start on anything
else rather than accept it: a value bash cannot compare skips every iteration, and the
give-up line would then blame the gateway for a typo.

Retries bound how many attempts are made; `HERMES_CRON_CALL_TIMEOUT` bounds each one. Both are
needed — a gateway that accepts the connection and then stalls would otherwise hold the
registrar open forever and emit none of the lines above.

The job is looked up by name before it is created, so restarts do not accumulate duplicates.
That holds for a single container against its own volume, which is what this image is for;
two containers sharing one volume and racing to register are not defended against.

### Delivery target

Without `HERMES_BRIEFING_CHANNEL` and `HERMES_BRIEFING_TO`, the briefing relies on implicit
routing — on a fresh container there may be no conversation for it to land in. Setting both
gives it an explicit destination:

```bash
  -e HERMES_BRIEFING_CHANNEL="slack" \
  -e HERMES_BRIEFING_TO="channel:C0123ABCDE" \
```

```bash
  -e HERMES_BRIEFING_CHANNEL="telegram" \
  -e HERMES_BRIEFING_TO="-1001234567890" \
```

The target's format belongs to the channel, so it is passed through exactly as given. Set both
or neither: a channel with no target registers cleanly and then delivers nothing, so the
container refuses to start rather than fail silently later.

### A note on `~/.openclaw/cron/jobs.json`

Earlier versions of this image pre-seeded that file. It was never a supported registration
path, and nothing writes it now. If your config volume still has one, it is inert — you can
remove it, and the image will not recreate it.

## Untrusted Content Boundary

Email subjects, sender headers, and calendar event titles are written by whoever can send
the user a message or an invite. `hermes-check` reads them and the heartbeat agent reads
`hermes-check`, so that text reaches an agent that has a shell. It is treated as data, not
as instruction.

Every untrusted value passes through a single choke point in `hermes-check` —
`sanitize_field()` — before it is emitted. That function:

- deletes C0 control characters and `DEL`, so no value can forge a line or a section header
- folds `U+0085`, `U+2028` and `U+2029` to a space, so no value can look like a line break
- deletes `<` and `>`, so no value can forge a fence marker
- collapses whitespace runs and trims the result
- truncates to `HERMES_FIELD_MAX_LEN` characters (default `200`), appending `…`

Printable text is otherwise left alone, including non-Latin scripts and emoji.

Sanitised values are then emitted inside explicit fences:

```
--- EMAIL ---
NEW_UNREAD: 2
URGENT: 0
VIP: 0
OTHER: 2
<untrusted-email>
  - From: alice@example.net | Subject: Q3 planning notes
</untrusted-email>
```

Counts and the `--- SUMMARY ---` block stay **outside** the fences: those are what the agent
acts on. Everything **inside** a fence is third-party text to be summarised. The heartbeat
prompt names these markers verbatim and instructs the agent never to follow, execute, or act
on fenced content, and to report anything instruction-shaped instead of doing it. This
matters most during heartbeats, which run with `lightContext: true` and so do not load
`SOUL.md` or `AGENTS.md`.

The morning briefing is the second reader of that output, and it is exposed the same way: it
runs `hermes-check` in an isolated session, which also does not load `SOUL.md` or `AGENTS.md`.
Its prompt therefore carries the same fencing contract, and that prompt is the one place the
briefing instructions exist — see [Morning Briefing](#morning-briefing).

Every run reports `SANITIZED: <n>` in its summary — the number of fields modified. It does
not raise `ACTION_NEEDED` on its own, because any subject containing an angle bracket trips
it; a *sustained* non-zero value is the signal worth investigating.

Operator check — this must print `1`:

```bash
docker exec hermes hermes-check | grep -cx -- '--- SUMMARY ---'
```

`-x` matters. A fenced line may legitimately *contain* the text `--- SUMMARY ---`, because
that is what a hostile subject looks like once it has been made inert; what must never
happen is a second line that **is** that header. Without `-x` the count rises whenever
someone is probing, and the check reads as a breach when it is the design working.

This reduces the efficacy of prompt injection; it does not eliminate it. The heartbeat agent
still runs with a full tool profile and an unrestricted shell.
