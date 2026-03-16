# EtherOS Kiosk Bootstrap

Turns any Debian 12 PC into a locked-down EtherOS subscriber terminal in one command.

## One-Liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk-bootstrap.sh | sudo bash
```

This installs everything silently, creates the `etheros-kiosk` user, configures autologin, and reboots into the kiosk.

---

## ISP Configuration

Before deploying to subscriber PCs, edit **`kiosk.conf`** with your ISP's details:

| Setting | Description | Default |
|---|---|---|
| `KIOSK_URL` | Subscriber terminal URL | `https://edge.etheros.ai/isp-portal/#/terminal` |
| `ISP_NAME` | Displayed on offline splash | `EtherOS` |
| `ACCENT_COLOR` | Hex color for offline splash | `#00C2CB` |
| `SUPPORT_PHONE` | Support number on offline splash | *(empty)* |
| `SUPPORT_EMAIL` | Support email on offline splash | *(empty)* |
| `KIOSK_USER` | Linux user to run kiosk | `etheros-kiosk` |
| `DISPLAY` | X display (usually `:0`) | `:0` |
| `NETWORK_TIMEOUT` | Seconds before offline splash shows | `30` |
| `ALLOW_USB_CONFIG_OVERRIDE` | Allow USB config updates on boot | `true` |

To pre-configure for your ISP, pass overrides on the command line:

```bash
curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk-bootstrap.sh \
  | sudo bash -s -- \
    --url "https://edge.etheros.ai/isp-portal/#/terminal" \
    --isp "Pinecrest Fiber" \
    --color "#FF6B00"
```

---

## Flags

| Flag | Description |
|---|---|
| `--test` | Install everything **without** enabling autologin or lockdown. Preview the kiosk with: `sudo -u etheros-kiosk /usr/local/bin/etheros-kiosk-launch.sh` |
| `--url <url>` | Override the terminal URL |
| `--isp <name>` | Override the ISP display name |
| `--color <hex>` | Override the accent color |
| `--uninstall` | Full removal (stops service, removes user, optionally removes packages) |

---

## USB Config Override

Place a `kiosk.conf` file in the **root of any USB drive** and insert it on boot. The kiosk will detect and apply it automatically — no reimaging required.

This allows ISPs to push config changes (URL, branding, support contacts) to deployed terminals without touching the OS.

---

## Recovery / Admin Access

The kiosk runs on the physical machine's display but **does not affect SSH or any headless admin access**.

To recover a locked terminal:

1. Press **Ctrl+Alt+F2** to switch to TTY2
2. Log in as a sudo user
3. Run `sudo systemctl stop etheros-kiosk` to kill the kiosk
4. Make changes as needed
5. Run `sudo systemctl start etheros-kiosk` to resume

---

## File Overview

| File | Purpose |
|---|---|
| `kiosk.conf` | ISP-editable configuration |
| `etheros-kiosk-bootstrap.sh` | Main install script |
| `etheros-kiosk-launch.sh` | Per-boot wrapper (USB check → network → Chromium) |
| `etheros-kiosk.service` | systemd unit (Restart=always) |
| `openbox-rc.xml` | Locked Openbox desktop (no right-click, no decorations) |
| `etheros-offline.html` | Offline splash page with auto-retry |
| `etheros-kiosk-uninstall.sh` | Full removal script |

---

## What Gets Installed

- `lightdm` — display manager with autologin
- `openbox` — minimal window manager
- `chromium` — kiosk browser (flags: `--kiosk`, no crash dialogs, no infobars, no restore session)
- `xdotool`, `unclutter` — fullscreen enforcement, cursor hiding
- `usbmount` — USB config override detection

Total install size: ~120 MB on a fresh Debian 12 minimal install.

---

## Uninstall

```bash
sudo /usr/local/bin/etheros-kiosk-uninstall.sh
```

Or via bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk-bootstrap.sh \
  | sudo bash -s -- --uninstall
```

---

## Notes

- **Admin/dev machines are unaffected.** The bootstrap only runs on machines where it is explicitly executed. Your VPS, dev laptop, or any machine accessed via SSH is never touched.
- **Test mode** (`--test`) is recommended for the first deployment at a new ISP site before rolling out to all subscriber PCs.
- Chromium runs with `--disable-sync`, `--no-first-run`, and `--disable-infobars` to prevent any browser popups from interrupting the kiosk experience.
