# 10. HTTPS reverse proxy — container 104 "proxy"

Script: `scripts/10-create-proxy.sh` · Configuration: `configs/containers/Caddyfile`

## Before / after

| Before | After |
|---|---|
| `http://anto-jellyfin:8096` | `https://jellyfin.maison.<domain>` |
| `https://serveur:8006` + certificate warning | `https://proxmox.maison.<domain>` with a valid padlock |
| A different port for each service | A single entry point, over HTTPS |

## The path of a request

```
iPhone ──(1) jellyfin.maison.<domain> ?──► AdGuard ──► "100.x.x.x (the proxy)"
iPhone ──(2) HTTPS via Tailscale─────────► Caddy ──► 192.168.1.27:8096 (Jellyfin)
```

## The certificate: DNS-01 challenge

Let's Encrypt has to verify that I own the domain. The usual method (a web page on port 80) is impossible: **no port is open**. Caddy therefore uses the **DNS challenge**: it creates a temporary TXT record at Cloudflare using an API token, Let's Encrypt reads it, then Caddy deletes it.

- A **wildcard certificate** `*.maison.<domain>` covers every service: their names do not appear in the public Certificate Transparency logs.
- Renewal is automatic.
- Caddy is downloaded with the `caddy-dns/cloudflare` module.

## The Cloudflare token: least privilege

- Permissions: `Zone → DNS → Edit` and `Zone → Zone → Read`, **on a single zone**. It cannot do anything else on the account.
- Entered with hidden input, verified against the Cloudflare API, then passed to the container via standard input: it is never displayed or written into a logged command.
- Stored in `/etc/caddy/cloudflare.env` with mode `640 root:caddy`. Template: `configs/cloudflare.env.example`.

## Technical details

- Caddy runs under a `caddy` system account, with only the `CAP_NET_BIND_SERVICE` capability.
- The Proxmox web interface uses a self-signed certificate: TLS verification is disabled **only** between the proxy and Proxmox, on the local network.
- The dashboard is published by `tailscale serve`, which only answers to its own name: Caddy rewrites the `Host` header (see [lessons learned](lessons-learned.md)).
- The script finds the services' addresses on its own from their container names, then tests each site before handing back control.

## Cloud equivalent

Azure Application Gateway (single entry point, TLS termination), managed certificates and Key Vault, managed identity scoped to a single DNS zone.
