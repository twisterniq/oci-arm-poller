# oci-arm-poller

Claims an Oracle Cloud **Always Free** compute instance the moment capacity appears in your
home region. Pure `bash` + `openssl` + `curl` + `jq` — it signs the OCI REST API directly, so
there is no OCI CLI to install. Runs on a GitHub Actions schedule, so your own machine can
stay off.

## What it does

Each run:

1. Resolves the newest Ubuntu 24.04 LTS image for the shape.
2. Tries to launch `VM.Standard.A1.Flex` (ARM, default 2 OCPU / 12 GB).
3. Optionally falls back to `VM.Standard.E2.1.Micro` (AMD, 1 GB).
4. Treats "Out of host capacity" and HTTP `429` as normal misses and exits quietly.
5. On success, optionally sends a Telegram message.

`MAX_ROUNDS` attempts per run keep several tries inside one billed CI minute.

## Configuration

Repository **variables** (non-sensitive):

| Variable | Meaning |
|---|---|
| `OCI_REGION` | region identifier, e.g. `eu-frankfurt-1` |
| `INSTANCE_NAME` | instance display name (default `server-1`) |
| `ARM_OCPUS`, `ARM_MEMORY_GB` | ARM shape size (default `2` / `12`) |
| `ALLOW_MICRO` | `true` to fall back to the AMD micro |
| `OCI_IMAGE_OCID` | optional, pins an image (otherwise resolved per run) |
| `MAX_ROUNDS`, `RETRY_SLEEP` | attempts per run / seconds between rounds |

Repository **secrets**:

| Secret | Meaning |
|---|---|
| `OCI_TENANCY`, `OCI_USER`, `OCI_FINGERPRINT` | from your OCI API key |
| `OCI_KEY` | the API key's private key (PEM) |
| `OCI_COMPARTMENT` | compartment OCID (the tenancy OCID works for the root) |
| `OCI_AD` | availability domain name, e.g. `xxxx:REGION-AD-1` |
| `OCI_SUBNET` | a **public** subnet OCID |
| `OCI_SSH_PUBLIC_KEY` | public key injected into the launched instance |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | optional notification |

Set them with `gh variable set` and `gh secret set`. Never commit keys or OCIDs — `.secrets/`
and `*.pem` are gitignored.

## Scheduling

GitHub disables scheduled workflows after 60 days of repository inactivity, so
`keepalive.yml` commits a timestamp once a day to keep the schedule enabled. Public repos get
unlimited Actions minutes; a private repo on the free plan gets 2,000/month and each job is
rounded up to one minute.

## Usage

- Automatic: see `cron` in `.github/workflows/claim.yml`.
- Manual: `gh workflow run claim.yml`.

## Notes

- Two AMD micro instances and one ARM instance can coexist, so a micro does not block the ARM box.
- Oracle may reclaim Always Free compute that sits idle (CPU / network below 20% over 7 days).
