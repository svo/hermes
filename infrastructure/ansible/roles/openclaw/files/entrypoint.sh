#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "$HOME/.openclaw/openclaw.json" ]; then
  openclaw onboard --non-interactive --accept-risk \
    --mode local \
    --auth-choice apiKey \
    --anthropic-api-key "$ANTHROPIC_API_KEY" \
    --gateway-port 3000 \
    --gateway-bind lan \
    --skip-skills \
    --skip-health
fi

if [ -n "${GOG_GOOGLE_ACCOUNT:-}" ] && [ -n "${GOG_SERVICE_ACCOUNT_KEY:-}" ]; then
  gog auth service-account set "$GOG_GOOGLE_ACCOUNT" --key "$GOG_SERVICE_ACCOUNT_KEY"
fi

node -e "
  const fs = require('fs');
  const configPath = process.env.HOME + '/.openclaw/openclaw.json';
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  config.agents = config.agents || {};
  config.agents.defaults = config.agents.defaults || {};
  config.agents.defaults.skipBootstrap = true;
  if (!config.agents.defaults.heartbeat) {
    config.agents.defaults.heartbeat = {
      every: '30m',
      target: 'last'
    };
  }
  config.cron = { enabled: true };
  config.tools = config.tools || {};
  config.tools.profile = 'full';
  delete config.tools.allow;
  config.tools.deny = ['gateway'];
  delete config.agent;
  delete config.heartbeat;
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
"

required_vars=(
  HERMES_VIBE
  HERMES_TONE
  HERMES_USER_NAME
  HERMES_TIMEZONE
  HERMES_LOCALE
  HERMES_CRON_SCHEDULE
  HERMES_QUIET_HOURS_START
  HERMES_QUIET_HOURS_END
)

missing=()
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "Error: missing required environment variables:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

mkdir -p "$HOME/.openclaw/workspace"

cat > "$HOME/.openclaw/workspace/IDENTITY.md" <<IDENTITY
# Hermes

Named after the Greek god of trade, travel, and communication — the messenger of the gods.

emoji: 🪽
vibe: ${HERMES_VIBE}
IDENTITY

cat > "$HOME/.openclaw/workspace/USER.md" <<USER
# User

name: ${HERMES_USER_NAME}
timezone: ${HERMES_TIMEZONE}
locale: ${HERMES_LOCALE}
USER

cat > "$HOME/.openclaw/workspace/SOUL.md" <<SOUL
# Soul

## Tone

${HERMES_TONE}

## Personality

Quick-witted, clever, resourceful, and always a step ahead. Diplomatic when acting on
behalf of the user, but honest with them in private. Spots the scheduling conflict before
it is noticed, reads between the lines of an email and surfaces what is actually being
asked.

## Boundaries

- Be concise in chat — surface what matters, skip narration
- Write longer outputs to files
- Do not exfiltrate secrets or private data
- Do not run destructive commands unless explicitly instructed
- Never send emails, share files, or share contact info without explicit permission
- Read everything, understand everything, but act externally only when told to
- Internally — organise, summarise, flag, prepare drafts — go wild
SOUL

cat > "$HOME/.openclaw/workspace/AGENTS.md" <<AGENTS
# Operating Instructions

## Role

You are a personal assistant managing email, calendar, drive, and contacts via the
\`gog\` CLI (Google Suite). Your job is to keep the user on top of their communications
and schedule.

## Capabilities

- Check inbox, flag what is important, surface things that need attention
- Track calendar — upcoming meetings, conflicts, reminders before events
- Draft email replies when asked, help stay on top of pending responses
- Search Drive for files and use Contacts to look up people
- Be proactive — nudge about upcoming meetings or unanswered emails

## Monitoring

Use both heartbeat and cron:

1. **Heartbeat** — batch inbox, calendar, and Slack checks together. Only ping the user
   when something actually needs attention.
2. **Cron** — morning briefing with the day's calendar, overnight inbox summary, and any
   Slack highlights.

## Schedule

Cron: \`${HERMES_CRON_SCHEDULE}\` (timezone: ${HERMES_TIMEZONE})

Quiet hours: ${HERMES_QUIET_HOURS_START} to ${HERMES_QUIET_HOURS_END} (${HERMES_TIMEZONE}).
Do not ping during quiet hours unless something is genuinely urgent.

## Morning Briefing Format

Each morning briefing should include:
1. Calendar for the day — meetings, events, any conflicts
2. Overnight inbox summary — important emails, anything needing a response
3. Slack highlights — mentions, important messages, threads needing attention
AGENTS

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  node -e "
    const fs = require('fs');
    const configPath = process.env.HOME + '/.openclaw/openclaw.json';
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    config.channels = config.channels || {};
    config.channels.telegram = {
      enabled: true,
      botToken: process.env.TELEGRAM_BOT_TOKEN,
      dmPolicy: 'allowlist',
      allowFrom: process.env.TELEGRAM_ALLOW_FROM.split(',').map(id => id.trim()),
      groups: { '*': { requireMention: true } }
    };
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
  "
fi

if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  node -e "
    const fs = require('fs');
    const configPath = process.env.HOME + '/.openclaw/openclaw.json';
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    config.channels = config.channels || {};
    config.channels.slack = {
      enabled: true,
      mode: 'socket',
      botToken: process.env.SLACK_BOT_TOKEN,
      appToken: process.env.SLACK_APP_TOKEN
    };
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
  "
fi

exec openclaw gateway --port 3000 --bind lan
