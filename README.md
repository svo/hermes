# Hermes

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
  -e GOG_GOOGLE_ACCOUNT="you@yourdomain.com" \
  -e GOG_SERVICE_ACCOUNT_KEY="/root/.openclaw/service-account.json" \
  -v /opt/hermes/data:/root/.openclaw \
  -p 127.0.0.1:3000:3000 \
  svanosselaer/hermes-service:latest
```

On first run, the entrypoint automatically configures OpenClaw via non-interactive onboarding and sets up Google Suite access via gog. Configuration is persisted to the volume at `/root/.openclaw` so subsequent starts skip onboarding.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key for the OpenClaw gateway |
| `GOG_GOOGLE_ACCOUNT` | No | Google account email for gog service account auth |
| `GOG_SERVICE_ACCOUNT_KEY` | No | Path (inside the container) to the GCP service account JSON key file |

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
   https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/contacts
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
