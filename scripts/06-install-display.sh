#!/bin/bash
# Home Cloud - shows the monitoring screen on the HDMI output
# cage (Wayland kiosk compositor) + full-screen chromium, unprivileged "kiosque" account
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
if ! systemctl is-active --quiet supervision; then echo "ERROR: the collector (supervision) is not running."; exit 1; fi

echo "=== 1. Installing cage and chromium (no unnecessary packages) ==="
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
  cage chromium fonts-dejavu-core fonts-noto-core dbus-user-session

echo
echo "=== 2. Dedicated 'kiosque' account (no password, no admin rights) ==="
id kiosque >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin kiosque
usermod -aG video,render,input kiosque
passwd -l kiosque >/dev/null
id kiosque

echo
echo "=== 3. PAM session for cage ==="
cat > /etc/pam.d/cage <<'FIN_PAM'
auth    required pam_unix.so nullok
account required pam_unix.so
session required pam_unix.so
session required pam_systemd.so
FIN_PAM

echo
echo "=== 4. Display service on tty1 ==="
cat > /etc/systemd/system/ecran-supervision.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - monitoring screen (cage + chromium) on tty1
After=systemd-user-sessions.service supervision.service getty@tty1.service
Wants=supervision.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=kiosque
PAMName=cage
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/usr/bin/cage -- /usr/bin/chromium --kiosk --ozone-platform=wayland --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble --disable-features=Translate --password-store=basic --check-for-update-interval=31536000 http://127.0.0.1:8088
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
FIN_UNITE

systemctl daemon-reload
systemctl enable ecran-supervision.service
systemctl restart ecran-supervision.service

echo
echo "=== 5. Check (15 seconds) ==="
sleep 15
echo -n "Display: "; systemctl is-active ecran-supervision || true
journalctl -u ecran-supervision -n 15 --no-pager | cut -c1-200
echo
echo "DONE. Look at the screen plugged into the server!"
echo "To go back to the text console: systemctl stop ecran-supervision"
