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
    lightContext: true,
    isolatedSession: true,
    prompt: 'Run: hermes-check — then act on the output. Notify user only if ACTION_NEEDED is yes with a concise summary of the reasons. Otherwise respond HEARTBEAT_OK. Do not run any other commands.',
    activeHours: {
      start: process.env.HERMES_QUIET_HOURS_END,
      end: process.env.HERMES_QUIET_HOURS_START,
      timezone: process.env.HERMES_TIMEZONE
    }
  };
  config.tools.loopDetection = {
    enabled: true,
    warningThreshold: 5,
    criticalThreshold: 10,
    globalCircuitBreakerThreshold: 15
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
mkdir -p "$HOME/.openclaw/hermes-check"

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

Personal assistant managing email, calendar, drive, and contacts via \`gog\` CLI (Google Suite). Keep the user on top of comms and schedule.

## Monitoring

\`hermes-check\` is a pre-processing pipeline. Run it during heartbeats instead of
calling gog commands individually — it fetches inbox and calendar, classifies urgency,
detects conflicts, tracks already-seen messages, and outputs a structured summary.

If ACTION_NEEDED is no, respond HEARTBEAT_OK.
If ACTION_NEEDED is yes, notify the user with a concise summary.

For deeper investigation (full email bodies, drafting replies, drive/contacts), use
\`gog\` commands directly.

VIP senders can be added to \`~/.openclaw/hermes-check/vip-senders.txt\` (one email or
domain per line).

**Cron** (\`${HERMES_CRON_SCHEDULE}\`, tz: ${HERMES_TIMEZONE}): morning briefing — run
\`hermes-check\`, then use \`gog\` for the full day's calendar and overnight inbox summary.
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
