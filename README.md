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
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key for the OpenClaw gateway |
| `GOG_GOOGLE_ACCOUNT` | No | Google account email for gog service account auth |
| `GOG_SERVICE_ACCOUNT_KEY` | No | Path (inside the container) to the GCP service account JSON key file |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token from @BotFather |
| `TELEGRAM_ALLOW_FROM` | With `TELEGRAM_BOT_TOKEN` | Comma-separated Telegram user IDs to allow |
| `SLACK_BOT_TOKEN` | No | Slack bot token (`xoxb-...`) from the Slack app settings |
| `SLACK_APP_TOKEN` | With `SLACK_BOT_TOKEN` | Slack app-level token (`xapp-...`) with `connections:write` scope |
| `HERMES_VIBE` | Yes | Personality vibe descriptors |
| `HERMES_TONE` | Yes | Communication tone descriptors |
| `HERMES_USER_NAME` | Yes | User's name |
| `HERMES_TIMEZONE` | Yes | Timezone for scheduling |
| `HERMES_LOCALE` | Yes | Spelling and language conventions |
| `HERMES_CRON_SCHEDULE` | Yes | Cron expression for morning briefing |
| `HERMES_QUIET_HOURS_START` | Yes | Quiet hours start time (e.g. `20:00`) |
| `HERMES_QUIET_HOURS_END` | Yes | Quiet hours end time (e.g. `08:00`) |

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

On startup, the entrypoint automatically configures the Telegram channel in OpenClaw with group chats set to require `@mention`. When `TELEGRAM_ALLOW_FROM` is set, the DM policy is `allowlist` — only the listed Telegram user IDs can message the bot. Without it, the policy falls back to `pairing` (unknown users get a pairing code for the owner to approve).

To find your Telegram user ID, message the bot without `TELEGRAM_ALLOW_FROM` set — the pairing prompt will show it.

## Slack Integration

Connect Hermes to Slack so you can chat with your assistant from any Slack workspace.

### Setup

1. Create a Slack app at https://api.slack.com/apps using the manifest in [`infrastructure/slack-app-manifest.json`](infrastructure/slack-app-manifest.json) — this configures Socket Mode, bot scopes, and event subscriptions automatically
2. Go to Basic Information > App-Level Tokens > generate a token with `connections:write` scope — this is your `SLACK_APP_TOKEN` (`xapp-...`)
3. Install the app to the workspace and go to OAuth & Permissions to copy the Bot User OAuth Token — this is your `SLACK_BOT_TOKEN` (`xoxb-...`)
4. Pass both tokens as environment variables:

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -e ANTHROPIC_API_KEY="your-api-key" \
  -e SLACK_BOT_TOKEN="xoxb-your-slack-bot-token" \
  -e SLACK_APP_TOKEN="xapp-your-slack-app-token" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

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

## Switching from API Key to Claude Subscription

If you have a Claude Pro or Max subscription, you can use it instead of an API key.

1. On a machine with Claude Code installed, generate a setup token:
   ```bash
   claude setup-token
   ```
2. Copy the token and paste it into the running container:
   ```bash
   docker exec -it hermes openclaw models auth paste-token --provider anthropic
   ```

3. Set the subscription as the default auth method:
   ```bash
   docker exec -it hermes openclaw models auth order set --provider anthropic anthropic:manual anthropic:default
   ```

## Workspace Instructions

On startup, the entrypoint generates OpenClaw workspace files at `~/.openclaw/workspace/` using the `HERMES_*` environment variables and sets `agent.skipBootstrap: true` so OpenClaw uses the pre-seeded files directly:

| File | Content |
|---|---|
| `IDENTITY.md` | Name, vibe, and emoji |
| `SOUL.md` | Persona, tone, and boundaries |
| `AGENTS.md` | Operating instructions — role, capabilities, monitoring, schedule, and morning briefing format |
| `USER.md` | User name, timezone, and locale |

These files are injected into the agent's context at the start of every session, so Hermes has detailed operating guidance available immediately without needing an initial brief.

All `HERMES_*` variables are required — the container will fail on startup if any are missing. This makes the configuration explicit and avoids hidden assumptions about identity, tone, or scheduling.
