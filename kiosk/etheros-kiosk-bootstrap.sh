#!/usr/bin/env bash
# ============================================================
#  EtherOS Kiosk Bootstrap — Sprint 4F
#  Turns a Debian 12 minimal install into a locked-down
#  EtherOS subscriber terminal kiosk.
#
#  Usage:
#    sudo bash etheros-kiosk-bootstrap.sh [OPTIONS]
#    curl -fsSL <url> | sudo bash -s -- [OPTIONS]
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

# ── Resolve script directory ──────────────────────────────
# Works whether run as a file OR piped via curl | bash
# When piped, BASH_SOURCE[0] is empty/unset — we fall back
# to downloading companion files from GitHub raw.
GITHUB_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/kiosk"
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -f "$_src" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
else
  SCRIPT_DIR=""   # piped mode — no local files available
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
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-kiosk-uninstall.sh" ]; then
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

# ── Step 0: Ensure apt sources include 'main' ─────────────
echo -e "${BOLD}[0/8] Verifying apt sources…${RESET}"

SOURCES_FILE="/etc/apt/sources.list"
SOURCES_DIR="/etc/apt/sources.list.d"

_has_main=false
# Check sources.list
if grep -qE '^deb .+ main' "$SOURCES_FILE" 2>/dev/null; then
  _has_main=true
fi
# Check sources.list.d
if grep -rqE '^deb .+ main' "$SOURCES_DIR/" 2>/dev/null; then
  _has_main=true
fi
# Check DEB822 format (bookworm+)
if grep -rqE '^Components:.*main' "$SOURCES_DIR/" 2>/dev/null; then
  _has_main=true
fi

if ! $_has_main; then
  warn "No 'main' component found in apt sources — adding Debian Bookworm main repository"
  cat > /etc/apt/sources.list.d/etheros-bookworm.list << 'APT_EOF'
# Added by EtherOS Kiosk Bootstrap
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
APT_EOF
  success "Added Debian Bookworm main repository"
else
  success "apt sources look good"
fi

# ── Load or create kiosk.conf ─────────────────────────────
ETHEROS_DIR="/etc/etheros"
CONFIG_FILE="$ETHEROS_DIR/kiosk.conf"

mkdir -p "$ETHEROS_DIR"

# Try to copy bundled kiosk.conf if available (file mode)
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/kiosk.conf" ] && [ ! -f "$CONFIG_FILE" ]; then
  cp "$SCRIPT_DIR/kiosk.conf" "$CONFIG_FILE"
  info "Installed default kiosk.conf to $CONFIG_FILE"
elif [ ! -f "$CONFIG_FILE" ]; then
  # Try to download from GitHub
  if curl -fsSL "$GITHUB_RAW/kiosk.conf" -o "$CONFIG_FILE" 2>/dev/null; then
    info "Downloaded kiosk.conf from GitHub"
  else
    # Write minimal default inline
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

# Core packages — all available in Debian 12 bookworm main
PACKAGES=(
  # X display server
  xorg
  xinit
  x11-xserver-utils
  # Lightweight window manager
  openbox
  # Hide cursor when idle
  unclutter
  # Network check tool
  curl
  wget
  # Fonts
  fonts-open-sans
  fonts-liberation
)

apt-get install -y --no-install-recommends "${PACKAGES[@]}" 2>&1 \
  | grep -E "^(Setting up|Unpacking|E:)" || true

# ── Chromium: try multiple install paths ──────────────────
CHROMIUM_BIN=""

# Path 1: chromium package (Debian 12 main)
if apt-get install -y --no-install-recommends chromium 2>/dev/null \
   && command -v chromium &>/dev/null; then
  CHROMIUM_BIN="chromium"
  success "Installed chromium (Debian package)"
fi

# Path 2: chromium-browser (Ubuntu / some derivatives)
if [ -z "$CHROMIUM_BIN" ]; then
  if apt-get install -y --no-install-recommends chromium-browser 2>/dev/null \
     && command -v chromium-browser &>/dev/null; then
    CHROMIUM_BIN="chromium-browser"
    success "Installed chromium-browser"
  fi
fi

# Path 3: Google Chrome via .deb (x86_64 only)
if [ -z "$CHROMIUM_BIN" ] && [ "$ARCH" = "x86_64" ]; then
  warn "Chromium not in apt — trying Google Chrome .deb"
  CHROME_DEB="/tmp/google-chrome.deb"
  if wget -q "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
       -O "$CHROME_DEB" 2>/dev/null; then
    apt-get install -y "$CHROME_DEB" 2>/dev/null || \
      apt-get install -yf 2>/dev/null || true
    rm -f "$CHROME_DEB"
    CHROMIUM_BIN=$(command -v google-chrome-stable || command -v google-chrome || true)
    [ -n "$CHROMIUM_BIN" ] && success "Installed Google Chrome as fallback"
  fi
fi

if [ -z "$CHROMIUM_BIN" ]; then
  error "Could not install Chromium or Chrome. Manually install a Chromium-based browser."
  error "Then re-run this script — it will skip already-installed packages."
  exit 1
fi

# Save which binary to use
echo "CHROMIUM_BIN=\"$CHROMIUM_BIN\"" >> "$CONFIG_FILE"

# ── USB automount: udiskie replaces usbmount on Debian 12 ─
if apt-get install -y --no-install-recommends udiskie 2>/dev/null; then
  success "Installed udiskie (USB automount)"
else
  warn "udiskie not available — USB config override will be skipped"
fi

success "All packages installed (Chromium: $CHROMIUM_BIN)"

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
  usermod -aG audio,video,input,plugdev "$KIOSK_USER" 2>/dev/null || true
  success "User $KIOSK_USER already exists — verified groups"
fi

KIOSK_HOME="/home/$KIOSK_USER"

# ── Step 3: Install offline splash page ───────────────────
echo ""
echo -e "${BOLD}[3/8] Installing offline splash page…${RESET}"

OFFLINE_DEST="$ETHEROS_DIR/etheros-offline.html"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-offline.html" ]; then
  cp "$SCRIPT_DIR/etheros-offline.html" "$OFFLINE_DEST"
else
  if ! curl -fsSL "$GITHUB_RAW/etheros-offline.html" -o "$OFFLINE_DEST" 2>/dev/null; then
    warn "Could not download offline page — creating minimal fallback"
    cat > "$OFFLINE_DEST" << OFFLINE_FALLBACK
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>EtherOS — Connecting</title>
<meta http-equiv="refresh" content="15">
<style>body{background:#0a1628;color:#e2e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;}
h1{color:ACCENT_COLOR_PLACEHOLDER;font-size:2rem;} p{color:#64748b;margin-top:1rem;}</style></head>
<body><div><h1>ISP_NAME_PLACEHOLDER</h1><p>Connecting to network…</p><p>Support: SUPPORT_PHONE_PLACEHOLDER</p></div></body></html>
OFFLINE_FALLBACK
  fi
fi

# Inject config values
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

OB_CONF_DEST="$ETHEROS_DIR/openbox-rc.xml"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/openbox-rc.xml" ]; then
  cp "$SCRIPT_DIR/openbox-rc.xml" "$OB_CONF_DEST"
else
  curl -fsSL "$GITHUB_RAW/openbox-rc.xml" -o "$OB_CONF_DEST"
fi

success "Openbox config installed (no menus, no decorations)"

# ── Step 5: Install kiosk launch wrapper ──────────────────
echo ""
echo -e "${BOLD}[5/8] Installing kiosk launch wrapper…${RESET}"

LAUNCH_DEST="/usr/local/bin/etheros-kiosk-launch.sh"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-kiosk-launch.sh" ]; then
  cp "$SCRIPT_DIR/etheros-kiosk-launch.sh" "$LAUNCH_DEST"
else
  curl -fsSL "$GITHUB_RAW/etheros-kiosk-launch.sh" -o "$LAUNCH_DEST"
fi

# Inject kiosk user
sed -i "s|KIOSK_USER_PLACEHOLDER|${KIOSK_USER}|g" "$LAUNCH_DEST"
chmod +x "$LAUNCH_DEST"

success "Launch wrapper installed at $LAUNCH_DEST"

# ── Step 6: Install systemd service ───────────────────────
echo ""
echo -e "${BOLD}[6/8] Installing systemd service…${RESET}"

SERVICE_DEST="/etc/systemd/system/etheros-kiosk.service"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-kiosk.service" ]; then
  cp "$SCRIPT_DIR/etheros-kiosk.service" "$SERVICE_DEST"
else
  curl -fsSL "$GITHUB_RAW/etheros-kiosk.service" -o "$SERVICE_DEST"
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

UNINSTALL_DEST="$ETHEROS_DIR/etheros-kiosk-uninstall.sh"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-kiosk-uninstall.sh" ]; then
  cp "$SCRIPT_DIR/etheros-kiosk-uninstall.sh" "$UNINSTALL_DEST"
else
  curl -fsSL "$GITHUB_RAW/etheros-kiosk-uninstall.sh" -o "$UNINSTALL_DEST"
fi

chmod +x "$UNINSTALL_DEST"
success "Uninstall script saved to $UNINSTALL_DEST"

# Also save this bootstrap to /etc/etheros for offline re-use
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/etheros-kiosk-bootstrap.sh" ]; then
  cp "$SCRIPT_DIR/etheros-kiosk-bootstrap.sh" "$ETHEROS_DIR/etheros-kiosk-bootstrap.sh"
else
  curl -fsSL "$GITHUB_RAW/etheros-kiosk-bootstrap.sh" \
    -o "$ETHEROS_DIR/etheros-kiosk-bootstrap.sh" 2>/dev/null || true
fi

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
  echo "   curl -fsSL $GITHUB_RAW/etheros-kiosk-bootstrap.sh | sudo bash"
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
