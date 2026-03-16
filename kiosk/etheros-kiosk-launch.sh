#!/usr/bin/env bash
# ============================================================
#  EtherOS Kiosk Launch Wrapper
#  /usr/local/bin/etheros-kiosk-launch.sh
#  Runs as KIOSK_USER on every boot via etheros-kiosk.service
# ============================================================

CONFIG_FILE="/etc/etheros/kiosk.conf"
USB_CONF="/media/usb/kiosk.conf"
OFFLINE_PAGE="/etc/etheros/etheros-offline.html"

# ── 1. USB config override ────────────────────────────────
# If a USB drive is mounted with a kiosk.conf, use it
if [ -f "$USB_CONF" ]; then
  echo "[etheros-kiosk] USB config found — applying override"
  cp "$USB_CONF" "$CONFIG_FILE"
fi

# ── 2. Load config ────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

KIOSK_URL="${KIOSK_URL:-https://edge.etheros.ai/isp-portal/#/terminal}"
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-20}"
CHROMIUM_EXTRA_FLAGS="${CHROMIUM_EXTRA_FLAGS:-}"
DISPLAY_RESOLUTION="${DISPLAY_RESOLUTION:-}"

# ── 3. Start X display server if not running ──────────────
if ! pgrep -x Xorg > /dev/null && ! pgrep -x X > /dev/null; then
  if [ -n "$DISPLAY_RESOLUTION" ]; then
    startx -- -s 0 -dpms &
  else
    startx -- -s 0 -dpms &
  fi
  sleep 3
fi

export DISPLAY=:0

# ── 4. Set resolution (if configured) ─────────────────────
if [ -n "$DISPLAY_RESOLUTION" ]; then
  xrandr -s "$DISPLAY_RESOLUTION" 2>/dev/null || true
fi

# ── 5. Disable screen blanking + power saving ─────────────
xset s off         2>/dev/null || true
xset s noblank     2>/dev/null || true
xset -dpms         2>/dev/null || true

# ── 6. Hide cursor after 3s of inactivity ─────────────────
unclutter -idle 3 -root &

# ── 7. Network connectivity check ────────────────────────
echo "[etheros-kiosk] Waiting up to ${NETWORK_TIMEOUT}s for network…"
LAUNCH_URL="$KIOSK_URL"
CONNECTED=false

for i in $(seq 1 "$NETWORK_TIMEOUT"); do
  if curl -fsS --max-time 3 --head "$KIOSK_URL" > /dev/null 2>&1; then
    CONNECTED=true
    echo "[etheros-kiosk] Network OK — launching terminal"
    break
  fi
  sleep 1
done

if [ "$CONNECTED" = false ]; then
  echo "[etheros-kiosk] No network after ${NETWORK_TIMEOUT}s — showing offline page"
  LAUNCH_URL="file://${OFFLINE_PAGE}"
fi

# ── 8. Start Openbox window manager ───────────────────────
openbox --config-file /etc/etheros/openbox-rc.xml &
sleep 1

# ── 9. Find Chromium binary ───────────────────────────────
CHROMIUM_BIN=""
for bin in chromium chromium-browser google-chrome google-chrome-stable; do
  if command -v "$bin" > /dev/null 2>&1; then
    CHROMIUM_BIN="$bin"
    break
  fi
done

if [ -z "$CHROMIUM_BIN" ]; then
  echo "[etheros-kiosk] ERROR: No Chromium/Chrome binary found"
  # Show error on screen via xmessage fallback
  xmessage -center "EtherOS: Chromium not installed. Contact your ISP." &
  exit 1
fi

# ── 10. Clear previous Chromium crash flags ───────────────
CHROMIUM_PROFILE="/home/$(whoami)/.config/chromium/Default"
if [ -f "$CHROMIUM_PROFILE/Preferences" ]; then
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g' \
    "$CHROMIUM_PROFILE/Preferences" 2>/dev/null || true
fi

# ── 11. Launch Chromium in kiosk mode ─────────────────────
echo "[etheros-kiosk] Launching: $CHROMIUM_BIN → $LAUNCH_URL"

exec "$CHROMIUM_BIN" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-session-crashed-bubble \
  --disable-restore-session-state \
  --disable-translate \
  --disable-features=TranslateUI \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --disable-background-networking \
  --disable-sync \
  --no-default-browser-check \
  --disable-component-update \
  --check-for-update-interval=31536000 \
  --autoplay-policy=no-user-gesture-required \
  --enable-features=OverlayScrollbar \
  --window-position=0,0 \
  --window-size=1920,1080 \
  --start-fullscreen \
  --user-data-dir="/home/$(whoami)/.config/chromium-kiosk" \
  $CHROMIUM_EXTRA_FLAGS \
  "$LAUNCH_URL"
