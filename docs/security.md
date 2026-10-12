# Security

## Principles applied

| Principle | Implementation |
|---|---|
| **No public exposure** | Zero open ports on the ISP router; remote access only through Tailscale |
| **Zero trust** | Every device authenticates; the local network is not considered safe |
| **Least privilege** | Unprivileged containers; read-only media libraries for Jellyfin and Immich; read-only Proxmox token (PVEAuditor); Cloudflare token limited to the DNS of a single zone; `kiosque` account with no rights for the screen; Caddy under a dedicated account |
| **Micro-segmentation** | A friend can be given access to Jellyfin alone, without seeing the rest of the network |
| **Defense in depth** | SMB3 minimum, no guest access, NetBIOS disabled; encrypted upstream DNS; end-to-end HTTPS on the client side |
| **Secrets kept out of code** | Passwords entered with hidden input; secrets in `640` files read by dedicated accounts; never in this repository |

## Secrets management

| Secret | Where it lives | Who can read it |
|---|---|---|
| Jellyfin API key, Proxmox token | `/etc/supervision.env` (host) | root, `supervision` group |
| Cloudflare token | `/etc/caddy/cloudflare.env` (proxy container) | root, `caddy` group |
| Immich database password | `/opt/immich/.env` (immich container) | root |
| Samba passwords | Samba database in the partage container | root |

The repository only contains `.example` templates. The `scripts/export-home-cloud.sh` script, used to extract the files from the server for this repository, does not include any of these files and scans for secret patterns before creating the archive. Hardware identifiers (serial numbers, MAC addresses), Tailscale addresses and the domain name have also been replaced with placeholder values.

## Malware in a shared folder

A malicious file dropped into a share can infect the computer of whoever opens it; the server itself does not execute it. Possible protections:

- **read-only** mounts wherever write access is not needed (already done for Jellyfin and Immich);
- in Samba, `veto files` to reject executable extensions (`.exe`, `.scr`, `.js`, `.vbs`…);
- antivirus (ClamAV) on the shared folders;
- one shared folder per person rather than a common folder.

## Known points of attention

- **AdGuard is a single point of failure** for name resolution on Tailscale devices.
- **Everything is in a single machine**: no high availability, no off-site copy.
- API key rotation (Jellyfin, Proxmox, Cloudflare) is manual.
