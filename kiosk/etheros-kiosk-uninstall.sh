#!/usr/bin/env bash
# ============================================================
#  EtherOS Kiosk — Uninstall / Recovery Script
#  Run as root on a kiosk PC to fully reverse the bootstrap.
#
#  Usage:
#    sudo bash etheros-kiosk-uninstall.sh
#
#  What this does:
#    1. Stops and disables the kiosk systemd service
#    2. Removes autologin for the kiosk user
#    3. Removes all /etc/etheros config files
#    4. Removes the launch wrapper from /usr/local/bin
#    5. Optionally removes the kiosk user account
#    6. Optionally removes installed packages (openbox, etc.)
#    7. Restores normal multi-user graphical login
# ============================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root. Use: sudo bash $0"
  exit 1
fi

echo "======================================================"
echo " EtherOS Kiosk — Uninstall"
echo "======================================================"
echo ""
echo "This will remove the EtherOS kiosk configuration"
echo "and restore normal desktop login."
echo ""
read -rp "Continue? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

KIOSK_USER="etheros-kiosk"
# Load from config if present
if [ -f /etc/etheros/kiosk.conf ]; then
  source /etc/etheros/kiosk.conf
fi

echo ""
echo "[1/6] Stopping kiosk service…"
systemctl stop etheros-kiosk 2>/dev/null || true
systemctl disable etheros-kiosk 2>/dev/null || true
rm -f /etc/systemd/system/etheros-kiosk.service
systemctl daemon-reload
echo "  ✓ Service stopped and removed"

echo ""
echo "[2/6] Removing autologin…"
# Remove getty autologin override
if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
  rm -rf /etc/systemd/system/getty@tty1.service.d/
  systemctl daemon-reload
fi
# Remove LightDM autologin if present
if [ -f /etc/lightdm/lightdm.conf ]; then
  sed -i '/autologin-user=/d' /etc/lightdm/lightdm.conf 2>/dev/null || true
  sed -i '/autologin-user-timeout=/d' /etc/lightdm/lightdm.conf 2>/dev/null || true
fi
echo "  ✓ Autologin removed"

echo ""
echo "[3/6] Removing EtherOS config files…"
rm -rf /etc/etheros/
echo "  ✓ /etc/etheros removed"

echo ""
echo "[4/6] Removing launch wrapper…"
rm -f /usr/local/bin/etheros-kiosk-launch.sh
echo "  ✓ Launch wrapper removed"

echo ""
echo "[5/6] Kiosk user account…"
if id "$KIOSK_USER" &>/dev/null; then
  read -rp "  Remove user '$KIOSK_USER' and their home directory? [y/N] " DEL_USER
  if [[ "$DEL_USER" == "y" || "$DEL_USER" == "Y" ]]; then
    pkill -u "$KIOSK_USER" 2>/dev/null || true
    userdel -r "$KIOSK_USER" 2>/dev/null || true
    echo "  ✓ User '$KIOSK_USER' removed"
  else
    echo "  Skipped — user '$KIOSK_USER' kept"
  fi
else
  echo "  User '$KIOSK_USER' not found — skipping"
fi

echo ""
echo "[6/6] Installed packages…"
read -rp "  Remove openbox, unclutter, and chromium? [y/N] " DEL_PKG
if [[ "$DEL_PKG" == "y" || "$DEL_PKG" == "Y" ]]; then
  apt-get remove -y openbox unclutter 2>/dev/null || true
  echo "  ✓ openbox, unclutter removed"
  echo "  Note: chromium kept (may be used by other applications)"
else
  echo "  Skipped — packages kept"
fi

echo ""
echo "======================================================"
echo " Uninstall complete."
echo ""
echo " The machine will boot normally on next restart."
echo " Log in with your admin account."
echo "======================================================"
