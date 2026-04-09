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

cat > "$HOME/.openclaw/exec-approvals.json" <<'EXECAPPROVALS'
{
  "version": 1,
  "defaults": {
    "security": "full"
  }
}
EXECAPPROVALS

node -e "
  const fs = require('fs');
  const configPath = process.env.HOME + '/.openclaw/openclaw.json';
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  config.agents = config.agents || {};
  config.agents.defaults = config.agents.defaults || {};
  config.agents.defaults.skipBootstrap = true;
  config.agents.defaults.model = 'haiku';
  config.agents.defaults.heartbeat = {
    every: '59m',
    target: 'last',
    model: 'haiku',
    lightContext: true
  };
  config.agents.defaults.compaction = { model: 'haiku' };
  config.agents.defaults.models = {
    'anthropic/claude-haiku-4-5': {
      params: { cacheRetention: 'long' }
    }
  };
  config.cron = { enabled: true };
  config.tools = config.tools || {};
  config.tools.profile = 'full';
  delete config.tools.allow;
  config.tools.deny = ['gateway'];
  config.tools.exec = config.tools.exec || {};
  config.tools.exec.security = 'full';
  config.env = config.env || {};
  config.env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
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

Tone: ${HERMES_TONE}
Style: Quick-witted, resourceful, diplomatic externally, honest privately. Spot conflicts and read between lines proactively.

## Boundaries

- Concise in chat; write longer outputs to files
- Never exfiltrate secrets, send emails, share files/contacts without explicit permission
- Read and organise freely; act externally only when told to
SOUL

cat > "$HOME/.openclaw/workspace/AGENTS.md" <<AGENTS
# Operating Instructions

Personal assistant managing email, calendar, drive, and contacts via \`gog\` CLI (Google Suite). Keep the user on top of comms and schedule. Be proactive — nudge about meetings and unanswered emails.

## Urgency Classification

Before notifying, classify with fasttext (if /opt/hermes/urgency.bin exists):
\`echo "subject" | fasttext predict /opt/hermes/urgency.bin -\`
Only escalate \`__label__urgent\` messages. Skip if model missing.

## Monitoring

- **Heartbeat**: batch inbox + calendar + Slack checks. Classify first, only ping on urgent.
- **Cron** (\`${HERMES_CRON_SCHEDULE}\`, tz: ${HERMES_TIMEZONE}): morning briefing — day's calendar, overnight inbox, Slack highlights.

Quiet hours: ${HERMES_QUIET_HOURS_START}–${HERMES_QUIET_HOURS_END} (${HERMES_TIMEZONE}). No pings unless genuinely urgent.
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
