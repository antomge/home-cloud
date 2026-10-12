#!/bin/bash
# Home Cloud - "partage" container (Samba): photos and films from the WD
set -euo pipefail

CTID=101
NOM=partage
UTIL=anto

echo "=== 0. Checks ==="
if pct status $CTID >/dev/null 2>&1; then echo "ERROR: container $CTID already exists, stopping."; exit 1; fi
if ! mountpoint -q /mnt/wd; then echo "ERROR: /mnt/wd is not mounted, stopping."; exit 1; fi
if ! ip link show vmbr0 >/dev/null 2>&1; then echo "ERROR: network bridge vmbr0 not found, stopping."; exit 1; fi
echo "OK"

echo
echo "=== 1. Share password for user '$UTIL' ==="
while true; do
  read -r -s -p "Choose a password: " MDP1 < /dev/tty; echo
  read -r -s -p "Type it again: " MDP2 < /dev/tty; echo
  if [ -n "$MDP1" ] && [ "$MDP1" = "$MDP2" ]; then break; fi
  echo "Entries differ or are empty, try again."
done

echo
echo "=== 2. Debian 13 template ==="
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64/ {print $2}' | sort -V | tail -n 1)
if [ -z "$MODELE" ]; then echo "ERROR: Debian 13 template not found."; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
echo "Template: $MODELE"

echo
echo "=== 3. Creating container $CTID ($NOM) ==="
pct create $CTID "local:vztmpl/$MODELE" \
  --hostname $NOM --ostype debian --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
  --onboot 1 --startup order=1 --timezone host
pct set $CTID -mp0 /mnt/wd/photos,mp=/srv/photos -mp1 /mnt/wd/films,mp=/srv/films
echo "Container created with photos and films bind mounts"

echo
echo "=== 4. Folder permissions (container UID 1000 = 101000 on the host) ==="
chown -R 101000:101000 /mnt/wd/photos /mnt/wd/films
chmod 755 /mnt/wd/photos /mnt/wd/films
ls -ln /mnt/wd

echo
echo "=== 5. Starting and waiting for the network ==="
pct start $CTID
for i in $(seq 1 30); do
  if pct exec $CTID -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! pct exec $CTID -- getent hosts deb.debian.org >/dev/null 2>&1; then echo "ERROR: no internet access in the container."; exit 1; fi
echo "Network OK"

echo
echo "=== 6. Updates and Samba installation ==="
pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get -y -q full-upgrade && apt-get -y -q install samba"

echo
echo "=== 7. User '$UTIL' ==="
pct exec $CTID -- groupadd -g 1000 $UTIL
pct exec $CTID -- useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin $UTIL
printf '%s\n%s\n' "$MDP1" "$MDP2" | pct exec $CTID -- smbpasswd -s -a $UTIL
unset MDP1 MDP2

echo
echo "=== 8. Samba configuration ==="
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
   # iPhone / Mac compatibility (Files app)
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
if pct exec $CTID -- testparm -s >/dev/null 2>&1; then echo "Configuration valid"; else echo "ERROR in smb.conf"; exit 1; fi
pct exec $CTID -- systemctl restart smbd
pct exec $CTID -- systemctl disable --now nmbd >/dev/null 2>&1 || true

echo
echo "=== 9. Summary ==="
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
MAC=$(pct config $CTID | sed -n 's/^net0:.*hwaddr=\([0-9A-Fa-f:]*\).*/\1/p')
echo -n "Samba: "; pct exec $CTID -- systemctl is-active smbd
pct exec $CTID -- ls -ld /srv/photos /srv/films
echo
echo "Container $CTID ($NOM)  |  IP: $IP  |  MAC: $MAC"
echo "From your PC: \\\\$IP\\photos   and   \\\\$IP\\films"
echo "User: $UTIL"
echo "DONE."
