# EtherOS Edge Deploy

One-command deployment scripts for the EtherOS edge node stack — turning any Debian 12 VM into a fiber-connected AI terminal for rural ISPs.

## Architecture

```
[EtherOS Terminal] ──── Fiber / GPN ──── [Edge Node VPS]
                                               │
                          ┌────────────────────┼────────────────────┐
                          │                    │                    │
                   [Ollama :11434]    [Open WebUI :3000]   [Nginx :80/443]
                          │                    │                    │
                   [ISP Portal API :3010]  [Marketplace API :3011]
                          │                    │
                   [ISP Portal UI]        [Agent Marketplace UI]
```

**Live deployment:** https://edge.etheros.ai  
**ISP Portal:** https://edge.etheros.ai/isp-portal/  
**Marketplace:** https://edge.etheros.ai/marketplace/  

---

## Quick Start — New ISP VM

```bash
curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/bootstrap.sh | bash
```

Installs Docker, clones this repo, stands up the full 8-container stack with TLS on any clean Debian 12 VM.

---

## Scripts

### Core Deployment

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | **Sprint 4A** — Portable one-command deployer for any ISP VM. Installs Docker, sets up the full stack, configures nginx + TLS. |
| `deploy.sh` | Original VPS deploy (Sprint 1) |
| `deploy-backends.sh` | **Sprint 3C/3D** — Deploys Node.js ISP Portal + Marketplace backends as Docker services |

### Backend Patches

| Script | Purpose |
|--------|---------|
| `fix-full-backends.sh` | **Sprint 3C/3D FINAL** — Complete backend rewrite with full data layer (dashboard, terminals, subscribers, agents, revenue, settings, AI chat via Ollama direct). Run this after `deploy-backends.sh`. |
| `fix-ollama-direct.sh` | Patches backends to call Ollama directly (bypasses Open WebUI auth) |
| `fix-backend-internal.sh` | Fixes Docker network hostname resolution |

### Sprint 3B — Branding

| Script | Purpose |
|--------|---------|
| `vps-install-3b.sh` | Applies EtherOS branding to Open WebUI (logo, colors, tenant config) |

### Sprint 1/2 — Initial Setup Fixes

| Script | Purpose |
|--------|---------|
| `fix-letsencrypt2.sh` | TLS cert fix — run if HTTPS isn't working |
| `fix-firstrun2.sh` | Creates first admin account |
| `fix-nginx2.sh` | Nginx config repair |
| `fix-ollama.sh` | Ollama service repair |
| `fix-model-loader.sh` | Model auto-loader repair |
| `fix-healthcheck.sh` | Docker healthcheck fix |
| `fix-disable-signup.sh` | Disables open registration |

---

## Docker Stack (8 containers)

| Container | Service name | Port | Purpose |
|-----------|-------------|------|---------|
| `etheros-ollama` | `ollama` | 127.0.0.1:11434 | Local LLM inference |
| `etheros-model-loader` | — | — | Auto-pulls models on startup |
| `etheros-open-webui` | `open-webui` | 127.0.0.1:3000 | Chat UI |
| `etheros-nginx` | `nginx` | 80/443 | Reverse proxy + TLS |
| `etheros-prometheus` | `prometheus` | 127.0.0.1:9090 | Metrics |
| `etheros-grafana` | `grafana` | 127.0.0.1:3001 | Dashboards |
| `etheros-isp-portal-backend` | `isp-portal-backend` | 127.0.0.1:3010 | ISP management API |
| `etheros-marketplace-backend` | `marketplace-backend` | 127.0.0.1:3011 | Agent marketplace API |

### Models
- `phi3:mini` — 2.2 GB, fast responses
- `llama3.1:8b` — 4.9 GB, higher quality

---

## ISP Tenant Management

```bash
# Add a new ISP tenant
./add-isp-tenant.sh <slug> <name> <domain> <accent_hex>

# Example
./add-isp-tenant.sh valley-fiber "Valley Fiber Co" fiber.example.com "#3B82F6"

# List tenants
./list-isp-tenants.sh

# Remove tenant
./remove-isp-tenant.sh <slug>
```

---

## Nginx Proxy Routes

| Path | Backend | Purpose |
|------|---------|---------|
| `/` | open-webui:8080 | Main AI chat UI |
| `/isp-portal/*` | isp-portal-backend:3010 | ISP management static app |
| `/isp-portal/api/*` | isp-portal-backend:3010/api/* | ISP Portal API |
| `/isp-portal/health` | isp-portal-backend:3010/health | Health check |
| `/marketplace/*` | marketplace-backend:3011 | Agent marketplace static app |
| `/marketplace/api/*` | marketplace-backend:3011/api/* | Marketplace API |
| `/marketplace/health` | marketplace-backend:3011/health | Health check |

---

## Project

- **Organization:** Fiber Gaming Network (FGN) / EtherOS
- **Contact:** admin@etheros.ai
- **Web portal:** https://etheros-web-portal.lovable.app
- **Repo:** https://github.com/FGN2025/etheros-edge-deploy
