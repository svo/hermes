<p align="center">
  <img src="icon.png" alt="Hermes" width="128">
</p>

# Hermes

[![Build Development](https://github.com/svo/hermes/actions/workflows/development.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/development.yml)
[![Build Builder](https://github.com/svo/hermes/actions/workflows/builder.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/builder.yml)
[![Build Service](https://github.com/svo/hermes/actions/workflows/service.yml/badge.svg)](https://github.com/svo/hermes/actions/workflows/service.yml)

Docker image running an [OpenClaw](https://docs.openclaw.ai) gateway with [gog](https://github.com/openclaw/gogcli) (Google Suite CLI) for Gmail, Calendar, Drive, and Contacts access.

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

## Pinned versions and upgrades

The three tools this repository fetches by hand are pinned to an exact version, and both
artefacts downloaded directly are verified against a checksum.

That is a narrower claim than "everything is pinned", and deliberately so. Debian packages come
from apt at whatever version the distribution serves, verified by apt against the repository
signature; `typescript`, `ts-node` and `@anthropic-ai/claude-code` install unpinned from npm on
the builder and development images. Those are the next thing to pin, not something this change
quietly covers.

| What | Where | Currently |
|---|---|---|
| OpenClaw (service image) | `roles/openclaw/defaults/main.yml` → `openclaw_version` | `2026.9.2` |
| OpenClaw CLI (builder image) | `roles/openclaw-cli/defaults/main.yml` → `openclaw_cli_version` | `2026.9.2` |
| gog | `roles/openclaw/defaults/main.yml` → `openclaw_gog_version` + `openclaw_gog_checksums` | `0.39.1` |
| fastText | `roles/fasttext/defaults/main.yml` → `fasttext_version` + `fasttext_checksum` | `0.9.2` |

`openclaw` used to install with `state: latest` and `gog` used to resolve `releases/latest` at
build time, so a rebuild that changed nothing in this repository could install a different
agent runtime. OpenClaw's configuration schemas declare `additionalProperties: false`, which
makes an unknown key a hard validation error rather than an ignored one — so an upstream key
rename turned a working image into one the gateway refused to load. The git history records the
loop: a bad option added, removed, an invalid timezone field removed twice, the version pinned
in `abc6127`, and unpinned again in `de52c54` the next day.

Upgrading is now a diff someone reads.

### Bumping OpenClaw

`openclaw_version` and `openclaw_cli_version` must move together and in the same commit: the
builder's `openclaw config validate` judges the container's configuration against the schema
*that* CLI carries, so a builder on a different version would pass a config the service image
refuses to load.

```bash
npm view openclaw dist-tags                 # what is published
# edit both defaults/main.yml files
.specs/007-gateway-supply-chain-hardening/tests/provisioning-test   # asserts the two agree
npm install -g openclaw@<the new version>   # the validator has to BE the new one
./bin/test                                  # config-schema now judges the new schema
```

That third line is the one people skip, and skipping it makes the check meaningless. `bin/test`'s
`config-schema` validates with whatever `openclaw` is on `PATH` — in CI, the copy baked into the
published builder image, which was built from the *previous* pin. Editing `openclaw_cli_version`
changes what the *next* builder image will carry; it does not change the validator running today.
So the sequence is: install the new CLI locally, run the gate, and read the result; then land the
bump, let `builder.yml` publish a builder carrying it, and CI validates against the new schema
from then on.

What the check then tells you is the thing worth knowing: `config-schema` runs the real entrypoint
against a stub and validates the configuration it produces. A schema change that would have
bricked every running container shows up as a red gate you are looking at, instead of as a dead
assistant on Friday.

### Bumping gog

```bash
curl -sSL https://github.com/openclaw/gogcli/releases/download/v<version>/checksums.txt
```

That file lists bare `<digest>  <filename>` pairs. Ansible wants `<algorithm>:<digest>`, so the
two `linux` lines become:

```yaml
openclaw_gog_checksums:
  amd64: sha256:<the gogcli_<version>_linux_amd64.tar.gz digest>
  arm64: sha256:<the gogcli_<version>_linux_arm64.tar.gz digest>
```

Change `openclaw_gog_version` to match. A digest that does not match fails the build — which is
the behaviour being bought, so do not "fix" a mismatch by copying whatever the build reports
without first working out why it changed.

To check the pins against what upstream is serving right now:

```bash
HERMES_CHECK_UPSTREAM=1 .specs/007-gateway-supply-chain-hardening/tests/provisioning-test
```

### The weekly rebuild

All three workflows still rebuild on a Thursday cron. That is worth keeping: it picks up
Debian base-image security patches. What it no longer does is silently change the agent
runtime, because the runtime version is now a value in this repository rather than whatever npm
served that morning. `--pull always` in the `docker run` above is likewise still right — it
fetches the newest *published image*, and what is inside that image is pinned by this commit.

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

> **About `-p 127.0.0.1:3000:3000`.** The gateway binds loopback by default, so under Docker's
> bridge networking that published port reaches nothing — it is inert, not broken, and Telegram,
> Slack, the heartbeat and `docker exec` all work without it. It is kept in these examples
> because it is exactly the line you need the moment you set `HERMES_GATEWAY_BIND=lan`, which is
> how you make the port live. The same `-p` appears in the Telegram, Slack and Google examples
> below and means the same thing in each. See
> [Gateway binding and authentication](#gateway-binding-and-authentication).

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
| `HERMES_GATEWAY_BIND` | No (default `loopback`) | Which interface the gateway listens on: `loopback`, `lan`, `tailnet` or `auto`. Anything but `loopback` requires `HERMES_GATEWAY_TOKEN` — see [Gateway binding and authentication](#gateway-binding-and-authentication) |
| `HERMES_GATEWAY_TOKEN` | With a non-loopback `HERMES_GATEWAY_BIND` | Shared token written to `gateway.auth.token`. The container refuses to start without it on a non-loopback bind |

## Gateway binding and authentication

The gateway binds **loopback** by default, and that is a change: it used to bind `lan` on every
start, with no `gateway.auth` configured by this image at all.

```bash
docker exec hermes openclaw config get gateway.bind        # loopback
```

`gateway.bind` is written on every start, so that answer is guaranteed. `gateway.auth.mode` is
not: on a loopback bind this image writes no `gateway.auth` at all, so what you read there is
whatever onboarding left — usually `token`, but on a config that never had one the key is simply
absent. See [What the container does not touch](#what-the-container-does-not-touch).

One line on startup reports both, and never the token:

```
gateway: bind=loopback auth=token
```

`auth=` is the mode actually in force, derived from the config after it is written — so `token`
there may mean onboarding's credential rather than one you supplied. `auth=none` means nothing
authenticates the gateway at all.

### The published port stops working, and that is the trade

**Read this before upgrading if you use `-p 127.0.0.1:3000:3000`.**

A `loopback` bind listens on `127.0.0.1` *inside the container*. Docker's published port
delivers traffic to the container's `eth0`, so under the default bridge networking a published
port no longer reaches the gateway. Nothing else is affected:

| Still works | Why |
|---|---|
| Telegram | the channel dials out; nothing connects to the container |
| Slack | Socket Mode, likewise outbound |
| `docker exec hermes …` | runs inside the container, where loopback is loopback |
| the morning briefing | its registrar probes `127.0.0.1` from inside the container |
| heartbeats and `hermes-check` | same |

So for the documented deployment — Telegram and/or Slack, and `docker exec` for
administration — loopback costs nothing and closes the gateway to every other container on the
Docker network. Only a deployment that actually connects to port 3000 needs the override.

### Publishing the port

Set both variables. The token is not optional, and the container refuses to start without it:

```bash
  -e HERMES_GATEWAY_BIND="lan" \
  -e HERMES_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  -p 127.0.0.1:3000:3000 \
```

Keeping `127.0.0.1:` on the `-p` is still worth doing — it limits the published port to the
host — but it is no longer the only thing standing between the LAN and an agent holding an
unrestricted shell. `HERMES_GATEWAY_TOKEN` becomes `gateway.auth.token` and
`gateway.auth.mode` is set to `token`; the value is rewritten from the variable on every start,
so rotating the credential means changing the variable and restarting, not editing the volume.

Upstream refuses a non-loopback bind with no auth path at all, logging
`refusing to bind gateway ... without auth` — so the alternative to this rule is not an
unauthenticated LAN gateway, it is a container that writes its whole configuration and then
dies on the last line. The check happens in phase 1 instead, before anything is written:

```
Error: missing required environment variables:
  HERMES_GATEWAY_TOKEN

HERMES_GATEWAY_TOKEN is required when HERMES_GATEWAY_BIND is not loopback.
  ...

Nothing has been written. The persisted configuration is untouched.
```

### Bind modes

`gateway.bind` takes a bind *mode*, not a host: `0.0.0.0` is rejected at startup, and so is
`127.0.0.1`. Use `lan` for every interface.

| `HERMES_GATEWAY_BIND` | Meaning | Token |
|---|---|---|
| `loopback` (default) | `127.0.0.1` inside the container | not needed |
| `lan` | every interface (`0.0.0.0`) | **required** |
| `tailnet` | the Tailscale address when available | **required** |
| `auto` | upstream's own choice | **required** — inside a container it resolves to `0.0.0.0`, so it is a LAN bind by another name |
| `custom` | rejected: it needs `gateway.customBindHost`, which this image does not write |  |

### Why the bind is written rather than left alone

Upstream's default is `loopback` — but **not inside a container**. Its gateway runbook says the
effective default in a detected container environment is `auto`, which resolves to `0.0.0.0`
precisely so that port-forwarding works. That is a reasonable default for the general case and
the wrong one here, where the thing behind the port is an agent holding an unrestricted shell.

So `gateway.bind` is written explicitly on every start rather than left unset. "Write nothing and
inherit the default" would bind every interface, which is what the container did before — and
writing it only at onboarding would leave an upgraded container's persisted `lan` in place for
ever, while the flag on the running process said something else.

### What the container does not touch

Onboarding configures token auth by default and generates a token when nothing else applies, so
a container that has ever onboarded normally already has a `gateway.auth.token` — one this image
did not create and does not manage. On a **loopback** bind that value is left exactly as it is:
overwriting it would break a client holding it, and writing `mode: none` would take
authentication away from a gateway that has it. The startup line reports the mode actually in
force, so `auth=token` there may mean onboarding's credential rather than yours.

To read or rotate that one, use upstream's own commands:

```bash
docker exec -it hermes openclaw gateway auth-token --show
```

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

The image includes [gog](https://github.com/openclaw/gogcli), a CLI for Google Suite (Gmail, Calendar, Drive, Contacts). Two authentication methods are supported:

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

The container's main configuration block is written with `openclaw config patch`, which
validates every key against the live schema as it writes. Objects merge recursively, arrays and
scalars replace, and `null` deletes — so a key upstream no longer recognises fails at the line
that wrote it, naming itself, and nothing reaches the file:

```
Error: the configuration this container tried to write was rejected.
  openclaw config patch said:
    Config validation failed: tools.loopDetection: Unrecognized key: "warningThreshold"

  Nothing was written; the persisted configuration is unchanged.
  Compare the key it names against: openclaw config schema
```

Those keys used to be hand-written into strict schemas by a read-modify-write that could not tell
a renamed key from a good one, so an upstream rename reached a running container as a gateway
that refused to load its own configuration. It also clobbered: a whole-object assignment deleted
every sibling the container did not write, including entries upstream's own migrations seed into
`agents.defaults.models`. A setting you tune by hand now survives a restart.

After all of that, and before the gateway starts, the entrypoint still runs `openclaw config
validate`. That gate is now the backstop rather than the only check — what is left for it is
everything the patch does not cover: the two channel blocks and the gateway auth block still
assemble their objects by hand, and the file can be edited on the volume between two starts. A
failure there costs one startup and names the key path:

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

### Exec approvals live in SQLite, not in a file

The container used to write `~/.openclaw/exec-approvals.json` with `defaults.security: full`.
It no longer writes it at all, because that file is a retired format — and a leftover one is
worse than useless. Approvals live in `~/.openclaw/state/openclaw.sqlite#exec_approvals_config`,
and a file carrying a non-empty policy is a legacy document upstream refuses to read past:

```
Legacy exec approvals exist at /root/.openclaw/exec-approvals.json.
Run `openclaw doctor --fix` before using exec approvals.
```

That was the answer `openclaw exec-policy show` gave in every container this image ever started.
The file written to configure exec approvals was blocking them.

**Read this if you rely on exec being restricted.** While the legacy file is there the approvals
subsystem refuses to report a policy at all; once it is gone, `openclaw approvals get` answers
normally and the configured policy is in force. The container has always declared
`tools.exec.security: full`, and `full` is the most permissive setting there is — so if the
blocked state had been holding anything back, this change stops holding it back. Bringing the
container's actual behaviour into line with the policy it has always declared is the point, but
it is still a change on the day it lands. Check what you are about to get:

```bash
docker exec hermes openclaw config get tools.exec.security
```

If that is not the policy you want, set it — before or after upgrading, either works, because the
container writes this key only when it finds none and never overwrites one.

The policy is now set at `tools.exec.security`, which is a key the schema recognises and the key
upstream sources the effective policy from when there are no stored overrides:

```bash
docker exec hermes openclaw config get tools.exec.security   # full
docker exec hermes openclaw exec-policy show                 # Effective: security=full
```

On a container that never had the legacy file, `exec-policy show` reports
`Approvals State: defaults (no stored overrides)` and sources the effective policy from that key.
On one that was migrated it reports `Approvals State: stored`, because the import put the
policy your old file carried into SQLite — which is the point of migrating rather than deleting,
and it means the stored value wins over the key. `exec-policy show` is the command that tells you
which of the two you have, and `openclaw approvals get` shows what is stored.

**Upgrading is automatic and normally happens once.** A volume created by an older image still
carries the file, so the first start after upgrading runs `openclaw doctor --fix` to import it
into SQLite and retire it, then never again — the step is guarded on the file being there. It is a
migration rather than a delete on purpose: an operator who tightened `defaults.security` keeps
that setting, where deleting the file would silently widen it.

If the file is still there afterwards the container starts anyway and says so, quoting what
doctor reported. There are two reasons it can happen, and they need different answers. Doctor may
have failed at something unrelated, in which case fixing that and restarting is enough. Or it may
have kept the file deliberately, because SQLite already holds approvals the legacy document
conflicts with:

```
Preserved canonical SQLite exec approvals and retained conflicting legacy JSON.
```

Only you can say which policy was meant. Read the file, then either delete it to keep the stored
policy, or apply its setting to the key and delete it:

```bash
docker exec hermes cat /root/.openclaw/exec-approvals.json
docker exec hermes openclaw config set tools.exec.security <value>
docker exec hermes rm /root/.openclaw/exec-approvals.json
docker restart hermes
```

Until it is gone, exec approvals stay blocked and the container repeats the message on every
start — which is deliberate: a live problem that stopped being mentioned would be worse.

`doctor --fix` is a maintenance pass over the whole configuration, not just the approvals import,
which is why it runs only while that file is present and never on a container created after this
change. If you would rather it did not run at all, do the migration yourself before upgrading —
read the file, set the key, delete it — and the container will find nothing to do.

To change the policy now, set the key rather than editing a file. `tools.exec.security` takes
`deny`, `allowlist` or `full`; prompting is a separate key, `tools.exec.ask`, which takes `off`,
`on-miss` or `always`:

```bash
docker exec hermes openclaw config set tools.exec.security allowlist
docker exec hermes openclaw config set tools.exec.ask on-miss
docker restart hermes
```

**The restart will not undo that.** The container supplies `full` only on the start that finds no
policy at all, and every start after that leaves whatever it finds — the same promise the old
write-if-absent guard on `exec-approvals.json` made, kept at the key the policy moved to. A start
that changed nothing says so:

```
exec: policy left as it was found; this start did not change it.
```

`tools.exec.ask` is never written by the container, and everything else under `tools.exec` —
`timeoutSeconds`, `grantExpiryDays`, `applyPatch` — survives a restart too, because the config is
merged rather than replaced.

### Credentials on disk are mode 0600

`openclaw.json` holds the Anthropic key, the Telegram bot token, both Slack tokens and — with a
non-loopback bind — the gateway token. It used to be written at the default `0644` on a host
bind mount, so every one of them was readable by any user on the host and by any other container
sharing that volume. The entrypoint now tightens these paths on every start, not only the first,
so an existing volume is corrected on upgrade:

```bash
docker exec hermes stat -c '%a' /root/.openclaw/openclaw.json       # 600
```

The other is `GOG_SERVICE_ACCOUNT_KEY`, tightened when the variable names a file — which is the
documented usage, and which for a Workspace deployment is a domain-wide delegated credential.

A third path, `exec-approvals.json`, is still named by that step but is normally absent: the
container stopped writing it (see above). It is tightened on the one path where it can still
exist — a volume whose migration has not yet succeeded — because until it is retired it holds an
exec policy on a bind mount the host can read.

**This is a floor, not a fix, and it should not be read as one.** The files are owned by `root`,
and `0600` only says *root can read them*. So it stops an unprivileged user on the host, and it
stops an unprivileged process in another container sharing the volume — but the agent runs as
root inside this container and can open every one of them, and so can any other container that
mounts the same volume and runs as root, which is the default. Anything that can start an agent
turn can still read every secret listed above. Real answers — Docker secrets, a SecretRef
indirection, running the agent as a non-root user — are tracked as
[`.specs/007-gateway-supply-chain-hardening/SPEC.md`](.specs/007-gateway-supply-chain-hardening/SPEC.md)
Open Question 5 and are not solved here.

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
UNREADABLE_MESSAGES: 0
<untrusted-email>
  - From: alice@example.net | Subject: Q3 planning notes
  - From: bob@example.net | Subject: Re: invoice 4471
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

## Monitoring Output

`hermes-check` is the pre-processing pipeline the heartbeat runs. Its report is a
line-oriented summary, and the counts outside the fences are what the agent acts on.

### VIP senders

`~/.openclaw/hermes-check/vip-senders.txt`, one entry per line. An entry matches only when
it is **exactly** the sender's address, or **exactly** the domain after the `@` — written
either way round:

```
bob@example.com     # this address
example.com         # anyone at this domain
@example.com        # the same thing
# blank lines and comments are ignored
```

Matching is case-insensitive. It is **not** a substring or suffix rule: `example.com` does
not match `mail.example.com`, and no sender becomes a VIP because a longer entry happens to
contain their address.

The sender is the address inside the angle brackets of the `From` header, not the display
name in front of it. A stranger whose display name is `"ceo@example.com"` is not a VIP —
which matters, because the display name is theirs to choose and the mailbox is not.

If you have an existing list, re-read it against that rule. Matching previously ran on
substring containment in the wrong direction, which meant an entry of `notexample.com`
flagged mail from `example.com`, and a sender whose `From` header carried no readable
address matched every line in the file. Some lists will have been flagging more than their
owner intended.

### The counts add up

A message lands in exactly one bucket — urgent, else VIP, else ordinary — so:

```
URGENT + VIP + OTHER == NEW_UNREAD
```

holds on every run and `OTHER` is never negative. A message that is both urgent and VIP is
counted once, as urgent. (It used to be counted in both and subtracted twice, which printed
`OTHER: -1`.)

### When monitoring itself is degraded

Three counters report what the run could not see. Any of them being non-zero sets
`ACTION_NEEDED`, because a check that ran but saw less than it should have is worth saying
out loud rather than reporting as a quiet day. A fourth line reports all-day events, which
are ordinary rather than a problem.

| Line | Meaning |
|---|---|
| `DATA_SOURCE_ERRORS: <n>` | upstream calls that failed or returned unusable data |
| `UNPARSEABLE_EVENTS: <n>` | calendar events excluded because their dates could not be read |
| `UNREADABLE_MESSAGES: <n>` | messages with no usable id, which cannot be tracked between runs |
| `ALL_DAY_EVENTS: <n>` | all-day events, reported separately and excluded from conflicts |

`ALL_DAY_EVENTS` is ordinary and does not raise `ACTION_NEEDED`; the other three do.

A failing upstream also names itself where it happened, as `DATA_SOURCE_ERROR: gmail` or
`DATA_SOURCE_ERROR: calendar`. The report is always complete: every section is emitted on
every path, including one where every upstream call fails. Silence is never a valid output —
previously a `gog` response that was not JSON aborted the script mid-report with no summary
at all, which reads exactly like a quiet inbox.

All-day events are reported rather than folded into conflict detection. An all-day event has
no start time and its end date is exclusive, so treating it as a timed event running from
midnight made it overlap every other event that day.

Operator check — the counts should reconcile and both error lines should be zero. `tail` will
not do here: the counts and the error lines sit in different sections, so ask for them by
name.

```bash
docker exec hermes hermes-check \
  | grep -E '^(NEW_UNREAD|URGENT|VIP|OTHER|UNREADABLE_MESSAGES|UNPARSEABLE_EVENTS|DATA_SOURCE_ERRORS):'
```

### Testing it

`hermes-check` runs end to end with no credentials, no network and no Google account, against
fixture responses served by a stub `gog`:

```bash
bin/hermes-check-test
```

## Contributing

Run the gate before you push:

```bash
./bin/test
```

That form runs the checks with the tooling on your own `PATH`. To run them out of the
*same image CI uses* — which is what makes "works on my machine" unreachable —
`infrastructure/packer/builder.pkr.hcl` declares `ENTRYPOINT ["./bin/test"]` with
`WORKDIR /working-dir`, and `build.sh` already mounts the repository there, so the container
form needs no entrypoint override:

```bash
docker run --rm -v "$(pwd)":/working-dir svanosselaer/hermes-builder
```

That is the command the `lint` job runs, and it is also what proves the image does what its
own definition says.

Seven checks, in order. Each prints one line; a failing check prints its full output, and the
summary at the end names every failure rather than only the first — one run should reveal
every problem, because a fail-fast gate turns a three-problem branch into three round trips.

| Check | What it does |
|---|---|
| `bash-n` | parses every shell script |
| `shellcheck` | `shellcheck -x -P SCRIPTDIR -s bash` over every shell script, at default severity |
| `ansible-lint` | the whole Ansible tree |
| `hermes-check` | `bin/hermes-check-test` — the monitoring suites |
| `config-schema` | runs the entrypoint against a stub and validates the config it writes |
| `gate-tests` | the checks that test the gate itself |
| `entrypoint-contract` | runs the builder image with no override and confirms `bin/test` starts |

Scripts are found by shebang, not by file extension. `hermes-check`, `bin/create-image` and
`bin/test` itself have no `.sh` suffix, and a glob would have skipped the file that carried
all five of the findings this gate was written to catch.

For fast local iteration, skip the container smoke test — the only check that needs a docker
daemon and a network:

```bash
SKIP_SLOW=1 ./bin/test
```

### When a check is skipped

A skip is not a pass, and the gate never prints one as the other. `SKIP <name> (<reason>)`
says which check did not run and why, and every skip is repeated in the closing summary so it
cannot scroll away. A skipped check does not fail the build; a real failure alongside it still
does.

Five checks can skip on a developer machine:

| Skip | Why, and what you lose |
|---|---|
| `shellcheck` | not installed — the whole check does not run. Install it, or use the container form. |
| `ansible-lint` | not installed — likewise. Neither linter is bundled; both are in the builder image. |
| `entrypoint-contract` | no docker daemon, or the daemon cannot see your checkout. It skips in CI too — see below. |
| `config-schema` validator | no `openclaw` on `PATH`. The generated config is still checked for shape; it is just not checked against the live schema. `npm install -g openclaw` closes it. |
| `hermes-check` | `bin/hermes-check-test` is missing, which should not happen on a full checkout. |

The `config-schema` one matters most. It is what catches a schema change that would otherwise
reach a running container — which is how `tools.loopDetection` came to carry three keys the
gateway would refuse to load, back when `openclaw` installed with `state: latest` and could
change under a build that changed nothing. The version is pinned now, so that no longer happens
by accident; it happens when somebody bumps `openclaw_version`, which is exactly when this
check should be the thing that answers. `infrastructure/ansible/roles/openclaw-cli` puts the
validator in the builder image, pinned to the same version, so CI runs it against the schema
the service image actually carries.

That last part is true of the *next* builder image, not the one on Docker Hub today: the role
arrives with this change, and `builder.yml` cannot publish it until this gate passes. Until a
builder built from this commit is pushed, CI prints the validator skip rather than running it.
The comment above the `Docker:Pull` step in `.github/workflows/lint.yml` documents how to
break that bootstrap by hand; the same procedure applies to a stale image as to a missing one.

The `entrypoint-contract` check skips in CI as well, and that is by design rather than a gap.
CI runs `bin/test` *inside* the builder container, and `lint.yml` deliberately does not mount
the Docker socket — mounting it would hand pull-request-authored code root on the runner. So
the check cannot reach a daemon and says so.

What covers the entrypoint contract in CI is the `lint` job itself: its one step is
`docker run --rm -v "$PWD":/working-dir svanosselaer/hermes-builder` with no `--entrypoint`.
If the image ever lost its `ENTRYPOINT ["./bin/test"]`, that step would not run the gate at
all, and the job would fail. The proof is one level up, where it needs no socket.
