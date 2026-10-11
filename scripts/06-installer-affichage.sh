#!/bin/bash
# Home Cloud - affichage de l'ecran de supervision sur la sortie HDMI
# cage (compositeur kiosque Wayland) + chromium en plein ecran, compte "kiosque" sans droits
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
if ! systemctl is-active --quiet supervision; then echo "ERREUR : le collecteur (supervision) ne tourne pas."; exit 1; fi

echo "=== 1. Installation de cage et chromium (sans paquets superflus) ==="
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
  cage chromium fonts-dejavu-core fonts-noto-core dbus-user-session

echo
echo "=== 2. Compte dedie 'kiosque' (aucun mot de passe, aucun droit admin) ==="
id kiosque >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin kiosque
usermod -aG video,render,input kiosque
passwd -l kiosque >/dev/null
id kiosque

echo
echo "=== 3. Session PAM pour cage ==="
cat > /etc/pam.d/cage <<'FIN_PAM'
auth    required pam_unix.so nullok
account required pam_unix.so
session required pam_unix.so
session required pam_systemd.so
FIN_PAM

echo
echo "=== 4. Service d'affichage sur tty1 ==="
cat > /etc/systemd/system/ecran-supervision.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - ecran de supervision (cage + chromium) sur tty1
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
echo "=== 5. Verification (15 secondes) ==="
sleep 15
echo -n "Affichage : "; systemctl is-active ecran-supervision || true
journalctl -u ecran-supervision -n 15 --no-pager | cut -c1-200
echo
echo "TERMINE. Regarde l'ecran branche sur le serveur !"
echo "Pour revenir a la console texte : systemctl stop ecran-supervision"
