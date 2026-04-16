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
  config.agents.defaults.model = 'anthropic/claude-haiku-4-5';
  config.agents.defaults.heartbeat = {
    every: '59m',
    target: 'last',
    model: 'anthropic/claude-haiku-4-5',
    lightContext: true,
    isolatedSession: true,
    prompt: 'You are Hermes, a personal assistant. Execute this bash command: hermes-check — then read its structured output. If the SUMMARY section shows ACTION_NEEDED: no, respond with exactly HEARTBEAT_OK. If ACTION_NEEDED: yes, send the user a concise summary of the REASONS. Do not run any other commands.',
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
  config.agents.defaults.compaction = { model: 'anthropic/claude-haiku-4-5' };
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
mkdir -p "$HOME/.openclaw/workspace/tmp"
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

Personal assistant managing email, calendar, drive, contacts, documents, and spreadsheets
via \`gog\` CLI (Google Suite). Keep the user on top of comms and schedule, and handle
document search, collection, archival, and delivery tasks on request.

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

## Document & File Operations

Search, collect, archive, and deliver documents from email and Drive.

**Email search** — use Gmail query syntax with \`gog gmail search\`:
\`\`\`
gog gmail search 'subject:(receipt OR invoice) after:2024/01/01 before:2024/06/30 has:attachment' --json --all
gog gmail messages search 'from:vendor@example.com newer_than:30d' --json --include-body
\`\`\`

**Download attachments** — per thread, into organised directories:
\`\`\`
gog gmail thread get <threadId> --download --out-dir ~/workspace/tmp/<label>/
\`\`\`

**Create archives** — \`zip\` is available:
\`\`\`
zip -r ~/workspace/tmp/archive.zip ~/workspace/tmp/collected/
\`\`\`

**Deliver files** — send via the user's messaging channel:
\`\`\`
openclaw message send --channel telegram --target <user> --media ~/workspace/tmp/archive.zip --force-document --message "Description"
\`\`\`

Telegram bot file limit is 50 MB. For larger archives, upload to Drive and share a link instead:
\`\`\`
gog drive upload ~/workspace/tmp/archive.zip --name "Archive Name" --parent <folderId>
\`\`\`

## Spreadsheet Operations

Create, populate, and share Google Sheets for summarising collected data.

**Create a sheet:**
\`\`\`
gog sheets create "Sheet Title" --sheets "Summary,Details"
\`\`\`

**Populate with data** — use \`--values-json\` for structured data:
\`\`\`
gog sheets update <spreadsheetId> 'A1' --values-json '[["Date","From","Amount","Description"]]'
gog sheets append <spreadsheetId> 'Summary!A:D' '2024-01-15|Vendor|49.99|Monthly subscription'
\`\`\`

**Format headers/cells:**
\`\`\`
gog sheets format <spreadsheetId> 'Sheet1!A1:D1' --format-json '{"textFormat":{"bold":true}}' --format-fields 'userEnteredFormat.textFormat.bold'
\`\`\`

**Template-based sheets** — if the user has a template spreadsheet in Drive:
1. Export it: \`gog sheets export <templateId> --format xlsx --out ~/workspace/tmp/template.xlsx\`
2. Upload as new sheet: \`gog drive upload ~/workspace/tmp/template.xlsx --convert --convert-to sheet --name "New Sheet"\`
3. Populate the copy with data using \`gog sheets update/append\`

**Export and deliver:**
\`\`\`
gog sheets export <spreadsheetId> --format xlsx --out ~/workspace/tmp/export.xlsx
gog sheets export <spreadsheetId> --format pdf --out ~/workspace/tmp/export.pdf
\`\`\`

## Working Directory

Use \`~/workspace/tmp/\` for all temporary file operations. Clean up after delivering
files to the user — remove downloaded attachments, archives, and exports.

**Cron** (\`${HERMES_CRON_SCHEDULE}\`, tz: ${HERMES_TIMEZONE}): morning briefing.
When this cron fires, execute these bash commands in order:
1. Run \`hermes-check\` and read its structured output — summarise email counts and any urgent/VIP items.
2. Run \`gog calendar list --date today\` for the full day's calendar.
3. Run \`gog gmail search 'newer_than:12h' --json\` for overnight inbox summary.
Then send the user a single concise morning briefing combining all results. Do not ask the user what to do — execute the commands yourself.
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
