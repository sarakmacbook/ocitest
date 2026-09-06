# 🎯 OCI Sniper v5.0.3

Always-Free instance grabber & manager for Oracle Cloud Infrastructure (OCI).

A self-hosted Flask web panel that hunts down OCI Always Free capacity (A1.Flex ARM / E2.1.Micro) with an automated retry loop, then lets you manage everything from one dashboard: instances, networking, firewall ports, quota usage — with Telegram alerts when an instance lands.

Formerly "OCI Provisioner". Same codebase, sharper aim: it sits scoped on your tenancy and fires the second free-tier capacity opens.

<a href="https://render.com/deploy?repo=https://github.com/sarakmacbook/ocitest">
  <img src="https://render.com/images/deploy-button.svg" alt="Deploy to Render" width="200">
</a>

<a href="https://railway.com/deploy/oracle-cloud-instance?referralCode=MPoxuF&utm_medium=integration&utm_source=template&utm_campaign=generic">
  <img src="https://railway.com/button.svg" alt="Deploy on Railway" width="200">
</a>

> 🟢 **Free 24/7 on Render** — ships with a built-in keep-alive self-ping, a `render.yaml` blueprint and health checks, so the free instance never sleeps. Full guide: **[Deploy on Render (free, 24/7)](#deploy-on-render-free-247)**.

## Features

- 🔁 **Auto-launch loop** — retries on `out of host capacity`, rotates availability domains, optional randomized delay; Telegram-pings you the moment an instance is provisioned
- 🖥️ **Full instance management** — list / reboot / delete single or DELETE ALL (type-to-confirm)
- 💾 **Boot volume management** — list / detach / re-attach to an existing instance / delete / launch a new instance from a detached volume
- 🌐 **Network bootstrap** — one click creates VCN + Internet Gateway + route + subnet if missing
- 🔓 **Firewall helper** — open ports via NSG or Security List with input validation (CIDR + port range)
- 📊 **Quota panel** — live Always Free usage: 2 A1 OCPUs / 12 GB RAM / 2 Micro / 200 GB boot volume
- 📡 **Telegram integration** — success/failure alerts + throttled live log streaming
- 🕙 **Keep-alive pinger** — built-in self-ping keeps free-tier hosts (Render etc.) awake 24/7
- 🔐 **Hardened auth** — Basic Auth (constant-time compare), per-IP rate limiting, fail-closed without password

## Deploy on Render (free, 24/7)

Render's free plan spins a web service **down after 15 minutes without inbound traffic** — deadly for a sniper that has to fire the second capacity appears. This repo ships everything needed to stay awake on the free tier: a **built-in self-ping daemon**, a **`render.yaml` blueprint** with health checks, and a recommended external-pinger backup.

<a href="https://render.com/deploy?repo=https://github.com/sarakmacbook/ocitest">
  <img src="https://render.com/images/deploy-button.svg" alt="Deploy to Render" width="200">
</a>

### Option A — one-click (Blueprint)

1. Push this repo to your own GitHub (fork it if it isn't yours).
2. Click the **Deploy to Render** button above and sign in with GitHub — Render reads the included `render.yaml`.
3. When prompted for `APP_PASSWORD`, enter a strong password (it's the Basic Auth password for every API call).
4. Click **Apply**. Render builds the root `Dockerfile` on the **Free** plan, then requests `/health` to verify the deploy — that first hit also boots the keep-alive pinger, so the idle timer never even starts.

### Option B — manual (dashboard)

1. Render dashboard → **New + → Web Service** → connect the repo.
2. **Runtime: Docker** — auto-detected from the root `Dockerfile`; leave build and start commands empty.
3. **Instance type: Free**.
4. **Environment → Add environment variable**: `APP_PASSWORD` = a strong password.
5. *(Optional but recommended)* **Settings → Health Check Path**: `/health` — every deploy then ends with a `/health` hit that (re)starts the pinger.
6. **Deploy**. The first build takes a few minutes (the OCI SDK compiles); the app then goes live at `https://<service-name>.onrender.com`.

### How it stays awake 24/7

| Piece | What it does |
|---|---|
| 🔁 **Self-ping daemon** | On boot the app reads `RENDER_EXTERNAL_URL` (injected by Render automatically) and a background thread requests `https://<your-app>.onrender.com/health` every 10 minutes (`KEEP_ALIVE_INTERVAL=600`). |
| ✅ **Why that works** | The self-request is genuine inbound traffic through Render's edge, so the 15-minute idle timer keeps resetting — the service, the provisioning loop and Telegram alerts never sleep. |
| 🩺 **Health check** | `render.yaml` sets `healthCheckPath: /health`, so Render itself hits the app right after every deploy/restart and re-arms the pinger from second zero. |

Keep-alive env vars (all optional — defaults are tuned for Render):

| Variable | Default | Purpose |
|---|---|---|
| `KEEP_ALIVE` | `true` | Enable the self-ping daemon. Set `false` to disable. |
| `KEEP_ALIVE_INTERVAL` | `600` | Seconds between self-pings (minimum 60). 600 s beats Render's 15-min idle window with margin. |
| `KEEP_ALIVE_URL` | *(auto)* | Public URL to ping. Auto-detected from `RENDER_EXTERNAL_URL` on Render; set it explicitly on other hosts, e.g. `https://your-app.onrender.com` or your Railway URL. |

### Recommended: add an external pinger (belt & suspenders)

The built-in pinger *prevents* sleep, but it can't *wake* the service once it's already stopped (a stopped process can't ping). That can happen after a failed deploy, a Render incident, or a manual stop/restart. A free external monitor covers exactly that case — and gives you uptime alerts:

- **cron-job.org** (free): *Create Cronjob* → URL `https://<your-app>.onrender.com/health` → schedule **Every 10 minutes** → Save.
- **UptimeRobot** (free): *Add New Monitor* → type **HTTP(s)** → URL `https://<your-app>.onrender.com/health` → interval **5 minutes** → Create.

With either one running, the service comes back within minutes even after a full stop.

### Free-plan math

The Render free plan includes **750 instance-hours per month**. Running 24/7 costs ≈ **730 hours** (31-day month), so one always-on service fits inside the free quota with ~20 h to spare.

### Verify it's working

```bash
curl https://<your-app>.onrender.com/health
# {"keep_alive":true,"keep_alive_interval":600,"keep_alive_url":"https://<your-app>.onrender.com","status":"ok","version":"5.0.3"}
```

- Render → **Logs** → filter for `keep-alive`: you should see `[keep-alive] ping OK` lines every 10 minutes.
- Your external monitor (if added) should show ~100% uptime.
- `curl https://<your-app>.onrender.com/api/version` → `{"version":"5.0.3"}`.

## Quick deploy (elsewhere)

### Railway

1. Connect repo → Railway builds the included root `Dockerfile` (a root `Dockerfile` always takes priority over Nixpacks/Railpack — keep only one deploy path in the repo)
2. Add env var `APP_PASSWORD`, deploy. `railway.toml` sets the `/health` healthcheck and gunicorn binds to `$PORT` automatically.

### Heroku

Uses the fixed `Procfile` (`web:` process). Set `APP_PASSWORD` in config vars.

### Docker anywhere

```bash
docker build -t oci-sniper .
docker run -d -p 5000:5000 -e APP_PASSWORD=changeme oci-provisioner
```

## Run locally

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
APP_PASSWORD=changeme python app.py
# http://localhost:5000
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `APP_PASSWORD` | *(none)* | Basic Auth password for all API endpoints. **Set this in production.** With no password set, GET pages still render but every state-changing POST is refused (fail-closed). |
| `PORT` | `5000` | Listen port (platform-provided on Railway/Heroku/Render). |
| `MAX_ATTEMPTS` | `0` | Max provisioning-loop attempts before giving up. `0` = unlimited. |
| `RATE_LIMIT_WINDOW` | `60` | Rate-limit window in seconds (per IP). |
| `RATE_LIMIT_MAX` | `30` | Max requests per window per IP before 429. |
| `KEEP_ALIVE` | `true` | Self-ping daemon that keeps free-tier hosts (Render etc.) from sleeping. |
| `KEEP_ALIVE_INTERVAL` | `600` | Ping interval in seconds (min 60). 600s = every 10 min. |
| `KEEP_ALIVE_URL` | *(auto)* | Public base URL to ping. Auto-detected from `RENDER_EXTERNAL_URL` on Render; set explicitly on other platforms, e.g. `https://your-app.onrender.com`. |

## How to use

1. Open the portal, paste your OCI API key file contents (or upload the `.pem`) — or paste the whole `~/.oci/config`; user/tenancy/fingerprint/region are parsed automatically.
2. **Scan shapes → images → subnets** to populate dropdowns. No subnet? *Create subnet* bootstraps VCN + IGW + route table.
3. Pick shape (A1.Flex OCPU/memory or Micro), boot volume (50–200 GB), SSH public key → **Start provisioning loop**.
4. Watch the live terminal; get Telegram ping on success. Loop stops via **Stop** or `MAX_ATTEMPTS`.
5. Manage instances from the quota panel: reboot / delete single, or DELETE ALL (type-to-confirm).
6. **Boot volumes:** *Scan volumes* → Detach from a stopped instance, **re-attach** a detached volume to an existing instance in the same AD (optional start after attach), delete, or launch a new instance from a detached volume.

> **Tip:** for A1.Flex, request the full 4 OCPU / 24 GB — if that's taken, drop to 2/12 and let the loop grab it. Both configs fit the free tier.

## Security notes

- All `/api/*` POST routes require Basic Auth (`APP_PASSWORD`). Constant-time comparison (`hmac.compare_digest`), rate-limited per IP.
- Fail-closed: no `APP_PASSWORD` set → every POST refused with 503.
- Private key lives only in your browser session, POSTed per-request over TLS, never written to disk by the app.
- "Remember account info" checkbox stores only non-secret OCIDs in localStorage — never the private key.
- Error responses sanitized/truncated (`safe_error_str`) so key material can't echo back through exceptions.
- Security headers on every response: `X-Frame-Options`, `nosniff`, HSTS, `Referrer-Policy`.

## API

All endpoints JSON. POST bodies take `user`, `tenancy`, `fingerprint`, `region`, `private_key` (+ endpoint-specific fields).

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/health` | Liveness + version + keep-alive status (no auth); each hit re-arms the keep-alive pinger |
| GET | `/api/version` | App version (no auth) |
| GET | `/api/status` | Automation loop status |
| GET | `/api/logs?offset=N` | Incremental log fetch |
| POST | `/api/list-shapes` · `list-images` · `list-subnets` · `list-vnics` | Resource discovery |
| POST | `/api/create-subnet` | VCN+IGW+route+subnet bootstrap |
| POST | `/api/free-tier-status` | Quota usage (A1 OCPU/RAM, micro count, boot GB) |
| POST | `/api/test-launch` | Dry-run validation of image/subnet/shape |
| POST | `/api/auto-launch-loop` | Start retry loop |
| POST | `/api/stop-loop` | Stop retry loop |
| POST | `/api/open-firewall` | NSG/SecurityList rule add (validates CIDR + ports) |
| POST | `/api/scan-security-rules` | Dump effective rules for a subnet |
| POST | `/api/test-telegram` · `send-telegram` | Telegram bot check / manual message |
| POST | `/api/list-instances` · `delete-instance` · `reboot-instance` · `delete-all-instances` | Instance management |
| POST | `/api/list-boot-volumes` | List boot volumes + instances (with `has_boot_volume`) |
| POST | `/api/detach-boot-volume` | Stop instance if running, then detach boot volume |
| POST | `/api/attach-boot-volume` | Re-attach a detached boot volume to an existing instance (same AD); optional `start_after` |
| POST | `/api/delete-boot-volume` · `launch-from-boot-volume` | Delete volume / launch a new instance from a detached volume |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Out of host capacity` forever | Normal for A1 in popular regions — leave the loop running; it grabs capacity the second it frees. Try all ADs. |
| Auth fails right after deploy | `APP_PASSWORD` not picked up — check platform env vars, redeploy. |
| Service sleeps anyway | Check Render **Logs** for `[keep-alive] ping OK` every 10 min. Ensure `KEEP_ALIVE=true` and — on non-Render hosts — `KEEP_ALIVE_URL` points at the public URL. If the service was fully stopped (failed deploy, manual stop), only an external pinger (cron-job.org / UptimeRobot) can wake it — see [Deploy on Render](#deploy-on-render-free-247). |
| Image dropdown empty | Your region may lack Ubuntu images for that shape — enable *all OS* mode or pick another shape. |

## Changelog v5.0.2 → v5.0.3

**Boot volume re-attach**
- New `POST /api/attach-boot-volume` attaches a detached boot volume to an existing instance in the same availability domain. Stops the instance if it is running, waits until the volume is AVAILABLE, refuses if the instance already has a boot volume, then optionally starts the instance (`start_after`).
- `/api/list-boot-volumes` now also returns `instances` with `has_boot_volume` so the UI can offer compatible targets.
- Boot Volume Management panel: **Re-attach boot volume to instance** — pick a detached volume + target instance, optional start-after-attach. Detached volume rows get an **Attach** button.

## Changelog v5.0.1 → v5.0.2

**Keep-alive — actually implemented**
- v5.0.1 documented a self-ping daemon (`KEEP_ALIVE` was even set in the Dockerfile) but `app.py` contained no such code. It exists now: a background thread pings `/health` on the public URL every 10 min, auto-detects `RENDER_EXTERNAL_URL`, honors `KEEP_ALIVE` / `KEEP_ALIVE_INTERVAL` / `KEEP_ALIVE_URL`, and is idempotently (re)armed by every `/health` hit. Keep-alive logging goes to stdout (`[keep-alive] ...`) so it shows in platform logs without spamming Telegram live logs.
- `/health` now reports `status`, `version`, `keep_alive`, `keep_alive_url`, `keep_alive_interval` (previously just `{"status":"ok"}`).
- New `GET /api/version` endpoint (was documented since v5.0, now real).

**Render deploy**
- New `render.yaml` Blueprint: Docker runtime, free plan, `/health` health check, `APP_PASSWORD` prompt, keep-alive defaults — enables the one-click **Deploy to Render** button.
- README: full [Deploy on Render (free, 24/7)](#deploy-on-render-free-247) guide — one-click + manual flow, how the self-ping beats the 15-min idle spin-down, external-pinger backup (cron-job.org / UptimeRobot), free-hours math (750 h/month vs ≈730 h for 24/7).

## Changelog v5.0 → v5.0.1

**Fixed**
- Railway/Heroku health check failing at boot: `python:3.12-slim` ships without timezone data, so
  `ZoneInfo("Asia/Phnom_Penh")` raised `ZoneInfoNotFoundError` during import and killed gunicorn before `/health` could answer.
- `app.py`: module-level tz lookups are now guarded (fall back to UTC); `tzdata` wheel added to requirements;
  Dockerfile installs the `tzdata` apt package; nixpacks setup adds `tzdata`.

## Changelog v4 → v5

**Fixed**
- Broken Procfile process name (`\web:` → `web:`) — Heroku builds failed silently
- Provisioning loop now honors `MAX_ATTEMPTS` env cap (was defined but dead code)

**Security**
- Basic Auth constant-time (`hmac.compare_digest`) instead of `==`
- Fail-closed when `APP_PASSWORD` unset — unauthenticated POSTs refused (v4 ran wide open)
- Per-IP sliding-window rate limiting (default 30 req/min) with `429` handler
- Error strings sanitized/truncated across all 15 API handlers — private-key material can't leak through exceptions
- Telegram live-log lines HTML-escaped before `parse_mode=HTML` send

**Input validation**
- `/api/open-firewall`: CIDR format, port range 1–65535, direction checked before mutating security lists
- Boot volume clamped 50–200 GB; Flex OCPUs/memory clamped to free-tier maxima (4/24)

**Robustness & UX**
- `/api/logs` tolerates garbage offset params; dev server threaded, debug off
- Optional localStorage persistence of account identifiers (never the private key)
- gunicorn access logs; `/health` reports version; new public `/api/version`

**Keep-alive**
- Built-in self-ping daemon (`KEEP_ALIVE=true`, default on): pings `/health` every 10 min so Render-style free tiers stay awake 24/7. URL auto-detected from `RENDER_EXTERNAL_URL`, else set `KEEP_ALIVE_URL`. Disable with `KEEP_ALIVE=false`.
