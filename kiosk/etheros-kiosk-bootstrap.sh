#!/usr/bin/env bash
# ============================================================
#  EtherOS Kiosk Bootstrap — Sprint 4F
#  Turns a Debian 12 minimal install into a locked-down
#  EtherOS subscriber terminal kiosk.
#
#  Usage:
#    sudo bash etheros-kiosk-bootstrap.sh [OPTIONS]
#
#  Options:
#    --test         Test mode: installs everything but does NOT
#                   enable autologin or kiosk lockdown. You can
#                   still preview the kiosk by running:
#                     sudo -u etheros-kiosk /usr/local/bin/etheros-kiosk-launch.sh
#    --url URL      Override KIOSK_URL without editing kiosk.conf
#    --isp NAME     Override ISP_NAME without editing kiosk.conf
#    --color HEX    Override ISP_ACCENT_COLOR (e.g. "#FF6B35")
#    --uninstall    Remove kiosk configuration (same as running
#                   etheros-kiosk-uninstall.sh)
#
#  Supports:
#    - Debian 12 (Bookworm) — recommended
#    - Ubuntu 22.04 / 24.04
#    - Any Debian-based distro with apt
#
#  Recovery:
#    Ctrl+Alt+F2  — drop to TTY2, log in as root
#    From TTY:    sudo systemctl stop etheros-kiosk
#                 sudo bash /etc/etheros/etheros-kiosk-uninstall.sh
#
#  USB config override:
#    Place a kiosk.conf file in the root of a USB drive.
#    The kiosk will apply it on next boot automatically.
# ============================================================

set -euo pipefail

# ── Colour output ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[etheros]${RESET} $*"; }
success() { echo -e "${GREEN}[etheros]${RESET} ✓ $*"; }
warn()    { echo -e "${YELLOW}[etheros]${RESET} ⚠ $*"; }
error()   { echo -e "${RED}[etheros]${RESET} ✗ $*" >&2; }

# ── Root check ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  error "Must run as root: sudo bash $0"
  exit 1
fi

# ── Parse arguments ───────────────────────────────────────
TEST_MODE=false
ARG_URL=""
ARG_ISP=""
ARG_COLOR=""
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)      TEST_MODE=true;   shift ;;
    --url)       ARG_URL="$2";     shift 2 ;;
    --isp)       ARG_ISP="$2";     shift 2 ;;
    --color)     ARG_COLOR="$2";   shift 2 ;;
    --uninstall) UNINSTALL=true;   shift ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Uninstall path ────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/etheros-kiosk-uninstall.sh" ]; then
    bash "$SCRIPT_DIR/etheros-kiosk-uninstall.sh"
  elif [ -f /etc/etheros/etheros-kiosk-uninstall.sh ]; then
    bash /etc/etheros/etheros-kiosk-uninstall.sh
  else
    error "Uninstall script not found. Manually remove /etc/etheros/ and disable etheros-kiosk.service"
    exit 1
  fi
  exit 0
fi

# ── Banner ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}======================================================"
echo -e " EtherOS Kiosk Bootstrap — Sprint 4F"
if [ "$TEST_MODE" = true ]; then
  echo -e " ${YELLOW}TEST MODE${RESET}${BOLD} — kiosk installed but not auto-started"
fi
echo -e "======================================================${RESET}"
echo ""

# ── Detect OS ─────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  error "This script requires a Debian/Ubuntu-based system with apt-get."
  exit 1
fi

OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")
info "System: $OS_PRETTY"
ARCH=$(uname -m)
info "Architecture: $ARCH"
echo ""

# ── Load or create kiosk.conf ─────────────────────────────
ETHEROS_DIR="/etc/etheros"
CONFIG_FILE="$ETHEROS_DIR/kiosk.conf"

mkdir -p "$ETHEROS_DIR"

# Copy bundled kiosk.conf if not already present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/kiosk.conf" ] && [ ! -f "$CONFIG_FILE" ]; then
  cp "$SCRIPT_DIR/kiosk.conf" "$CONFIG_FILE"
  info "Installed default kiosk.conf to $CONFIG_FILE"
elif [ ! -f "$CONFIG_FILE" ]; then
  # Write a minimal default config inline
  cat > "$CONFIG_FILE" << 'DEFAULT_CONF'
KIOSK_URL="https://edge.etheros.ai/isp-portal/#/terminal"
ISP_NAME="EtherOS"
ISP_ACCENT_COLOR="#00C2CB"
SUPPORT_PHONE="+1(480)808-0077"
SUPPORT_EMAIL="support@etheros.ai"
SUPPORT_URL="https://etheros.ai"
KIOSK_USER="etheros-kiosk"
DISPLAY_RESOLUTION=""
NETWORK_TIMEOUT=20
CHROMIUM_EXTRA_FLAGS=""
USB_CONFIG_OVERRIDE="yes"
DEFAULT_CONF
  info "Created default kiosk.conf at $CONFIG_FILE"
fi

# Load config
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Command-line overrides
[ -n "$ARG_URL" ]   && KIOSK_URL="$ARG_URL"
[ -n "$ARG_ISP" ]   && ISP_NAME="$ARG_ISP"
[ -n "$ARG_COLOR" ] && ISP_ACCENT_COLOR="$ARG_COLOR"

# Apply overrides back to config file
sed -i "s|^KIOSK_URL=.*|KIOSK_URL=\"$KIOSK_URL\"|" "$CONFIG_FILE"
sed -i "s|^ISP_NAME=.*|ISP_NAME=\"$ISP_NAME\"|" "$CONFIG_FILE"
sed -i "s|^ISP_ACCENT_COLOR=.*|ISP_ACCENT_COLOR=\"$ISP_ACCENT_COLOR\"|" "$CONFIG_FILE"

info "Kiosk URL:   $KIOSK_URL"
info "ISP Name:    $ISP_NAME"
info "Accent:      $ISP_ACCENT_COLOR"
info "Kiosk User:  $KIOSK_USER"
echo ""

# ── Step 1: System update + package install ───────────────
echo -e "${BOLD}[1/8] Installing required packages…${RESET}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

PACKAGES=(
  # X display server
  xorg
  xinit
  x11-xserver-utils
  # Lightweight window manager
  openbox
  # Chromium browser
  chromium
  # Hide cursor when idle
  unclutter
  # Network check tool
  curl
  # USB automount
  usbmount
  # Fonts for kiosk UI
  fonts-open-sans
  fonts-liberation
  # Optional: on-screen keyboard support for touchscreens
  # onboard
)

apt-get install -y --no-install-recommends "${PACKAGES[@]}" 2>&1 | grep -E "^(Setting up|Unpacking|E:)" || true

# Chromium fallback name
CHROMIUM_BIN=""
for bin in chromium chromium-browser; do
  if command -v "$bin" &>/dev/null; then
    CHROMIUM_BIN="$bin"
    break
  fi
done

if [ -z "$CHROMIUM_BIN" ]; then
  warn "chromium not found via apt — trying chromium-browser"
  apt-get install -y --no-install-recommends chromium-browser 2>/dev/null || true
  CHROMIUM_BIN=$(command -v chromium-browser || command -v chromium || true)
fi

if [ -z "$CHROMIUM_BIN" ]; then
  error "Could not install Chromium. Check your package sources."
  exit 1
fi

success "Packages installed (Chromium: $CHROMIUM_BIN)"

# ── Step 2: Create kiosk user ─────────────────────────────
echo ""
echo -e "${BOLD}[2/8] Setting up kiosk user…${RESET}"

if ! id "$KIOSK_USER" &>/dev/null; then
  useradd \
    --create-home \
    --shell /bin/bash \
    --comment "EtherOS Kiosk" \
    --groups audio,video,input,plugdev \
    "$KIOSK_USER"
  success "Created user: $KIOSK_USER"
else
  # Make sure kiosk user is in required groups
  usermod -aG audio,video,input,plugdev "$KIOSK_USER" 2>/dev/null || true
  success "User $KIOSK_USER already exists — verified groups"
fi

KIOSK_HOME="/home/$KIOSK_USER"

# ── Step 3: Install offline splash page ───────────────────
echo ""
echo -e "${BOLD}[3/8] Installing offline splash page…${RESET}"

OFFLINE_SRC="$SCRIPT_DIR/etheros-offline.html"
OFFLINE_DEST="$ETHEROS_DIR/etheros-offline.html"

if [ -f "$OFFLINE_SRC" ]; then
  cp "$OFFLINE_SRC" "$OFFLINE_DEST"
else
  # Download from GitHub if not in same dir
  curl -fsSL \
    "https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-offline.html" \
    -o "$OFFLINE_DEST" || {
      warn "Could not download offline page — creating minimal fallback"
      cat > "$OFFLINE_DEST" << OFFLINE_FALLBACK
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>EtherOS — Connecting</title>
<style>body{background:#0a1628;color:#e2e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;}
h1{color:#00C2CB;font-size:2rem;} p{color:#64748b;margin-top:1rem;}</style></head>
<body><div><h1>EtherOS</h1><p>Connecting to network…</p><p>Support: ${SUPPORT_PHONE}</p></div></body></html>
OFFLINE_FALLBACK
    }
fi

# Inject config values into offline page placeholders
sed -i "s|ACCENT_COLOR_PLACEHOLDER|${ISP_ACCENT_COLOR}|g" "$OFFLINE_DEST"
sed -i "s|ISP_NAME_PLACEHOLDER|${ISP_NAME}|g" "$OFFLINE_DEST"
sed -i "s|KIOSK_URL_PLACEHOLDER|${KIOSK_URL}|g" "$OFFLINE_DEST"
sed -i "s|SUPPORT_PHONE_PLACEHOLDER|${SUPPORT_PHONE:-}|g" "$OFFLINE_DEST"
sed -i "s|SUPPORT_EMAIL_PLACEHOLDER|${SUPPORT_EMAIL:-}|g" "$OFFLINE_DEST"
sed -i "s|SUPPORT_URL_PLACEHOLDER|${SUPPORT_URL:-}|g" "$OFFLINE_DEST"
sed -i "s|NETWORK_TIMEOUT_PLACEHOLDER|${NETWORK_TIMEOUT:-20}|g" "$OFFLINE_DEST"

success "Offline splash page installed"

# ── Step 4: Install Openbox config ────────────────────────
echo ""
echo -e "${BOLD}[4/8] Configuring Openbox (locked desktop)…${RESET}"

OB_CONF_SRC="$SCRIPT_DIR/openbox-rc.xml"
OB_CONF_DEST="$ETHEROS_DIR/openbox-rc.xml"

if [ -f "$OB_CONF_SRC" ]; then
  cp "$OB_CONF_SRC" "$OB_CONF_DEST"
else
  curl -fsSL \
    "https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/openbox-rc.xml" \
    -o "$OB_CONF_DEST"
fi

success "Openbox config installed (no menus, no decorations)"

# ── Step 5: Install kiosk launch wrapper ──────────────────
echo ""
echo -e "${BOLD}[5/8] Installing kiosk launch wrapper…${RESET}"

LAUNCH_SRC="$SCRIPT_DIR/etheros-kiosk-launch.sh"
LAUNCH_DEST="/usr/local/bin/etheros-kiosk-launch.sh"

if [ -f "$LAUNCH_SRC" ]; then
  cp "$LAUNCH_SRC" "$LAUNCH_DEST"
else
  curl -fsSL \
    "https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk-launch.sh" \
    -o "$LAUNCH_DEST"
fi

# Inject kiosk user into launch script
sed -i "s|KIOSK_USER_PLACEHOLDER|${KIOSK_USER}|g" "$LAUNCH_DEST"
chmod +x "$LAUNCH_DEST"

success "Launch wrapper installed at $LAUNCH_DEST"

# ── Step 6: Install systemd service ───────────────────────
echo ""
echo -e "${BOLD}[6/8] Installing systemd service…${RESET}"

SERVICE_SRC="$SCRIPT_DIR/etheros-kiosk.service"
SERVICE_DEST="/etc/systemd/system/etheros-kiosk.service"

if [ -f "$SERVICE_SRC" ]; then
  cp "$SERVICE_SRC" "$SERVICE_DEST"
else
  curl -fsSL \
    "https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk.service" \
    -o "$SERVICE_DEST"
fi

# Inject kiosk user
sed -i "s|KIOSK_USER_PLACEHOLDER|${KIOSK_USER}|g" "$SERVICE_DEST"

systemctl daemon-reload

if [ "$TEST_MODE" = true ]; then
  warn "TEST MODE — service installed but NOT enabled/started"
else
  systemctl enable etheros-kiosk
  success "Service enabled (will start on next boot)"
fi

# ── Step 7: Configure autologin ───────────────────────────
echo ""
echo -e "${BOLD}[7/8] Configuring autologin…${RESET}"

if [ "$TEST_MODE" = true ]; then
  warn "TEST MODE — autologin NOT configured"
else
  # Getty autologin (TTY1 → startx as kiosk user)
  mkdir -p /etc/systemd/system/getty@tty1.service.d/
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

  # .bash_profile: auto-startx on TTY1 login
  cat > "$KIOSK_HOME/.bash_profile" << 'BASH_PROFILE'
# EtherOS Kiosk — auto-start X on TTY1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx /usr/local/bin/etheros-kiosk-launch.sh -- -nolisten tcp 2>&1 | \
    logger -t etheros-kiosk
fi
BASH_PROFILE

  chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.bash_profile"
  systemctl daemon-reload
  success "Autologin configured for $KIOSK_USER on TTY1"
fi

# ── Step 8: Install uninstall script ──────────────────────
echo ""
echo -e "${BOLD}[8/8] Installing uninstall/recovery script…${RESET}"

UNINSTALL_SRC="$SCRIPT_DIR/etheros-kiosk-uninstall.sh"
UNINSTALL_DEST="$ETHEROS_DIR/etheros-kiosk-uninstall.sh"

if [ -f "$UNINSTALL_SRC" ]; then
  cp "$UNINSTALL_SRC" "$UNINSTALL_DEST"
else
  curl -fsSL \
    "https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk/etheros-kiosk-uninstall.sh" \
    -o "$UNINSTALL_DEST"
fi

chmod +x "$UNINSTALL_DEST"
success "Uninstall script saved to $UNINSTALL_DEST"

# Also copy this bootstrap to /etc/etheros for reference
cp "$0" "$ETHEROS_DIR/etheros-kiosk-bootstrap.sh" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}======================================================"
echo -e " EtherOS Kiosk Bootstrap Complete!"
echo -e "======================================================${RESET}"
echo ""

if [ "$TEST_MODE" = true ]; then
  echo -e "${YELLOW}TEST MODE ACTIVE${RESET}"
  echo ""
  echo " Everything is installed but the kiosk is NOT auto-started."
  echo " To preview exactly what a subscriber would see:"
  echo ""
  echo "   sudo -u $KIOSK_USER /usr/local/bin/etheros-kiosk-launch.sh"
  echo ""
  echo " To enable full kiosk mode (autologin + lockdown), re-run:"
  echo ""
  echo "   sudo bash $0 (without --test)"
  echo ""
else
  echo " Configuration:"
  echo "   Kiosk URL:    $KIOSK_URL"
  echo "   ISP:          $ISP_NAME"
  echo "   Kiosk User:   $KIOSK_USER"
  echo "   Config file:  $CONFIG_FILE"
  echo ""
  echo -e "${BOLD} To go live:${RESET}"
  echo "   Reboot the machine — it will boot directly to the EtherOS terminal."
  echo ""
  echo "   sudo reboot"
  echo ""
fi

echo -e "${BOLD} Recovery (always works):${RESET}"
echo "   Ctrl+Alt+F2 — drop to TTY2"
echo "   Log in as root or an admin user"
echo "   sudo systemctl stop etheros-kiosk   — stop the kiosk"
echo "   sudo bash $ETHEROS_DIR/etheros-kiosk-uninstall.sh — full removal"
echo ""
echo " USB config override:"
echo "   Place a kiosk.conf file in the root of a USB drive."
echo "   The kiosk will apply it on next boot automatically."
echo ""
echo -e "${BOLD} Config to customise:${RESET}  $CONFIG_FILE"
echo "======================================================"
