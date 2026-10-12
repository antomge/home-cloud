#!/bin/bash
# Home Cloud - "proxy" container: Caddy reverse proxy + Let's Encrypt HTTPS certificates
# Addresses: https://<service>.maison.example.com, reachable only through Tailscale.
# Wildcard certificate *.maison.example.com obtained via a DNS challenge at Cloudflare.
set -euo pipefail
NOM=proxy
DOMAINE=example.com                # <- replace with your own domain name
ZONE="maison.$DOMAINE"
STOCKAGE=local-lvm
IP_SERVEUR=192.168.1.33           # Proxmox host (web UI on 8006)
TS_SERVEUR=$(tailscale ip -4 | head -n1)   # Tailscale IP of the host: dashboard published by "tailscale serve" (port 80)
# "tailscale serve" only answers to its own name: fetch it to rewrite the Host header
NOM_TS_SERVEUR=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
if pct list | awk 'NR>1 {print $NF}' | grep -qx "$NOM"; then
  echo "A container named $NOM already exists, stopping."; exit 1
fi

# IPv4 address (home network) of a container, looked up by its name
ip_conteneur() {
  local id
  id=$(pct list | awk -v n="$1" 'NR>1 && tolower($NF) ~ n {print $1; exit}')
  [ -n "$id" ] || return 0
  pct exec "$id" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

echo "=== 1. Cloudflare token ==="
echo "(it is not shown while you type, that is normal)"
read -r -s -p "Paste the Cloudflare API token: " CF < /dev/tty; echo
VERIF=$(curl -fsS -H "Authorization: Bearer $CF" https://api.cloudflare.com/client/v4/user/tokens/verify || true)
if ! echo "$VERIF" | grep -q '"status":"active"'; then
  echo "ERROR: token rejected by Cloudflare. Check it and run again."; exit 1
fi
echo "Token is valid."

echo
echo "=== 2. Services found on the server ==="
IP_JELLYFIN=$(ip_conteneur jellyfin)
IP_IMMICH=$(ip_conteneur immich)
IP_ADGUARD=$(ip_conteneur adguard)
printf '  %-10s %s\n' jellyfin "${IP_JELLYFIN:-not found}" immich "${IP_IMMICH:-not found}" \
  adguard "${IP_ADGUARD:-not found}" proxmox "$IP_SERVEUR" tableau "$TS_SERVEUR"

echo
echo "=== 3. Debian 13 template and container creation ==="
CTID=$(pvesh get /cluster/nextid)
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '{print $2}' \
  | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -n1)
if [ -z "$MODELE" ]; then echo "ERROR: Debian 13 template not found"; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
pct create "$CTID" "local:vztmpl/$MODELE" \
  --hostname "$NOM" --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs "$STOCKAGE:4" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 1 --startup order=2 \
  --description "Proxy inverse Caddy : https://*.$ZONE (via Tailscale uniquement)"
cat >> "/etc/pve/lxc/$CTID.conf" <<'FIN_TUN'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
FIN_TUN
pct start "$CTID"
echo -n "Waiting for the network"
for i in $(seq 1 40); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 2
done
echo
pct exec "$CTID" -- bash -c 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade'
pct exec "$CTID" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates'

echo
echo "=== 4. Caddy with the Cloudflare DNS module ==="
URL='https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare'
for essai in 1 2 3; do
  if pct exec "$CTID" -- curl -fsSL -o /usr/bin/caddy "$URL"; then break; fi
  echo "Download failed (attempt $essai), retrying in 10 s..."; sleep 10
done
pct exec "$CTID" -- chmod 755 /usr/bin/caddy
pct exec "$CTID" -- caddy version
pct exec "$CTID" -- bash -c 'caddy list-modules | grep -q dns.providers.cloudflare' \
  && echo "Cloudflare module present."
pct exec "$CTID" -- bash -c 'id caddy >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy'
pct exec "$CTID" -- mkdir -p /etc/caddy

# The token goes through standard input: it shows up neither on screen nor in the process list
printf 'CF_API_TOKEN=%s\n' "$CF" | pct exec "$CTID" -- bash -c 'umask 027; cat > /etc/caddy/cloudflare.env'
unset CF
pct exec "$CTID" -- chown root:caddy /etc/caddy/cloudflare.env

echo
echo "=== 5. Configuration (Caddyfile) ==="
{
  echo "# Home Cloud - reverse proxy. Adding a service = one @name + handle block, then: systemctl reload caddy"
  echo "*.$ZONE {"
  echo "    tls {"
  echo "        dns cloudflare {env.CF_API_TOKEN}"
  echo "        resolvers 1.1.1.1"
  echo "    }"
  echo "    encode zstd gzip"
  echo
  if [ -n "$IP_JELLYFIN" ]; then
    echo "    @jellyfin host jellyfin.$ZONE"
    echo "    handle @jellyfin {"
    echo "        reverse_proxy $IP_JELLYFIN:8096"
    echo "    }"
  fi
  if [ -n "$IP_IMMICH" ]; then
    echo "    @immich host immich.$ZONE"
    echo "    handle @immich {"
    echo "        reverse_proxy $IP_IMMICH:2283"
    echo "    }"
  fi
  if [ -n "$IP_ADGUARD" ]; then
    echo "    @adguard host adguard.$ZONE"
    echo "    handle @adguard {"
    echo "        reverse_proxy $IP_ADGUARD:80"
    echo "    }"
  fi
  echo "    @proxmox host proxmox.$ZONE"
  echo "    handle @proxmox {"
  echo "        reverse_proxy https://$IP_SERVEUR:8006 {"
  echo "            transport http {"
  echo "                tls_insecure_skip_verify"
  echo "            }"
  echo "        }"
  echo "    }"
  echo "    @tableau host tableau.$ZONE"
  echo "    handle @tableau {"
  echo "        reverse_proxy $TS_SERVEUR:80 {"
  echo "            header_up Host $NOM_TS_SERVEUR"
  echo "        }"
  echo "    }"
  echo
  echo "    handle {"
  echo "        respond \"Service inconnu sur $ZONE\" 404"
  echo "    }"
  echo "}"
} | pct exec "$CTID" -- bash -c 'cat > /etc/caddy/Caddyfile'
pct exec "$CTID" -- caddy fmt --overwrite /etc/caddy/Caddyfile
pct exec "$CTID" -- bash -c 'set -a; . /etc/caddy/cloudflare.env; caddy validate --config /etc/caddy/Caddyfile' \
  2>&1 | tail -n 1

echo
echo "=== 6. Caddy service ==="
pct exec "$CTID" -- bash -c 'cat > /etc/systemd/system/caddy.service' <<'FIN_UNITE'
[Unit]
Description=Caddy - Home Cloud reverse proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/cloudflare.env
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
FIN_UNITE
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now caddy

echo
echo "=== 7. Tailscale ==="
pct exec "$CTID" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
echo
echo ">>> A link will be shown: open it and approve adding the machine to your Tailscale account."
pct exec "$CTID" -- tailscale up --accept-dns=false --hostname=anto-proxy
TSIP=$(pct exec "$CTID" -- tailscale ip -4 | head -n1)

echo
echo "=== 8. Obtaining the certificate (up to 2 minutes) ==="
for i in $(seq 1 24); do
  if pct exec "$CTID" -- journalctl -u caddy --no-pager | grep -q 'certificate obtained successfully'; then
    echo "Certificate *.$ZONE obtained."; break
  fi
  echo -n "."; sleep 5
done
echo
for s in jellyfin immich adguard proxmox tableau; do
  CODE=$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$s.$ZONE:443:127.0.0.1" "https://$s.$ZONE/" || true)
  printf '  %-10s https://%s.%s  ->  %s\n' "$s" "$s" "$ZONE" "$CODE"
done
echo "(200, 301, 302 or 401 = OK; 404 = service not configured; 000 = certificate problem)"

echo
echo "=================== SUMMARY ================="
echo "Container     : $CTID ($NOM)"
echo "Tailscale IP  : $TSIP   (name anto-proxy)"
echo "TO DO         : AdGuard > Filters > DNS rewrites > *.$ZONE -> $TSIP"
echo "============================================="
