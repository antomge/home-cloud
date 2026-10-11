#!/bin/bash
# Home Cloud - conteneur "partage" (Samba) : photos et films du WD
set -euo pipefail

CTID=101
NOM=partage
UTIL=anto

echo "=== 0. Verifications ==="
if pct status $CTID >/dev/null 2>&1; then echo "ERREUR : le conteneur $CTID existe deja, arret."; exit 1; fi
if ! mountpoint -q /mnt/wd; then echo "ERREUR : /mnt/wd n'est pas monte, arret."; exit 1; fi
if ! ip link show vmbr0 >/dev/null 2>&1; then echo "ERREUR : pont reseau vmbr0 introuvable, arret."; exit 1; fi
echo "OK"

echo
echo "=== 1. Mot de passe du partage pour l'utilisateur '$UTIL' ==="
while true; do
  read -r -s -p "Choisis un mot de passe : " MDP1 < /dev/tty; echo
  read -r -s -p "Retape-le : " MDP2 < /dev/tty; echo
  if [ -n "$MDP1" ] && [ "$MDP1" = "$MDP2" ]; then break; fi
  echo "Saisies differentes ou vides, recommence."
done

echo
echo "=== 2. Modele Debian 13 ==="
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64/ {print $2}' | sort -V | tail -n 1)
if [ -z "$MODELE" ]; then echo "ERREUR : modele Debian 13 introuvable."; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
echo "Modele : $MODELE"

echo
echo "=== 3. Creation du conteneur $CTID ($NOM) ==="
pct create $CTID "local:vztmpl/$MODELE" \
  --hostname $NOM --ostype debian --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
  --onboot 1 --startup order=1 --timezone host
pct set $CTID -mp0 /mnt/wd/photos,mp=/srv/photos -mp1 /mnt/wd/films,mp=/srv/films
echo "Conteneur cree avec les montages lies photos et films"

echo
echo "=== 4. Droits des dossiers (UID 1000 du conteneur = 101000 sur le serveur) ==="
chown -R 101000:101000 /mnt/wd/photos /mnt/wd/films
chmod 755 /mnt/wd/photos /mnt/wd/films
ls -ln /mnt/wd

echo
echo "=== 5. Demarrage et attente du reseau ==="
pct start $CTID
for i in $(seq 1 30); do
  if pct exec $CTID -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! pct exec $CTID -- getent hosts deb.debian.org >/dev/null 2>&1; then echo "ERREUR : pas d'acces internet dans le conteneur."; exit 1; fi
echo "Reseau OK"

echo
echo "=== 6. Mises a jour et installation de Samba ==="
pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get -y -q full-upgrade && apt-get -y -q install samba"

echo
echo "=== 7. Utilisateur '$UTIL' ==="
pct exec $CTID -- groupadd -g 1000 $UTIL
pct exec $CTID -- useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin $UTIL
printf '%s\n%s\n' "$MDP1" "$MDP2" | pct exec $CTID -- smbpasswd -s -a $UTIL
unset MDP1 MDP2

echo
echo "=== 8. Configuration Samba ==="
cat > /tmp/smb.conf <<'SMB'
[global]
   workgroup = WORKGROUP
   server string = Home Cloud
   server role = standalone server
   server min protocol = SMB3
   map to guest = never
   disable netbios = yes
   smb ports = 445
   log file = /var/log/samba/%m.log
   max log size = 1000
   # Compatibilite iPhone / Mac (app Fichiers)
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[photos]
   path = /srv/photos
   valid users = anto
   read only = no
   create mask = 0644
   directory mask = 0755

[films]
   path = /srv/films
   valid users = anto
   read only = no
   create mask = 0644
   directory mask = 0755
SMB
pct push $CTID /tmp/smb.conf /etc/samba/smb.conf
rm -f /tmp/smb.conf
if pct exec $CTID -- testparm -s >/dev/null 2>&1; then echo "Configuration valide"; else echo "ERREUR dans smb.conf"; exit 1; fi
pct exec $CTID -- systemctl restart smbd
pct exec $CTID -- systemctl disable --now nmbd >/dev/null 2>&1 || true

echo
echo "=== 9. Bilan ==="
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
MAC=$(pct config $CTID | sed -n 's/^net0:.*hwaddr=\([0-9A-Fa-f:]*\).*/\1/p')
echo -n "Samba : "; pct exec $CTID -- systemctl is-active smbd
pct exec $CTID -- ls -ld /srv/photos /srv/films
echo
echo "Conteneur $CTID ($NOM)  |  IP : $IP  |  MAC : $MAC"
echo "Depuis ton PC : \\\\$IP\\photos   et   \\\\$IP\\films"
echo "Utilisateur : $UTIL"
echo "TERMINE."
