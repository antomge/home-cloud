# 9. Private DNS and ad blocker — container 100 "adguard"

Script: `scripts/09-create-adguard.sh`

## Two roles in one

1. **Blocker**: AdGuard Home answers "does not exist" for ad-network and tracker domain names. Ads are never downloaded. Result measured on a public test page: **92 %** of elements blocked.
2. **Private DNS**: it knows the internal `*.maison.<domain>` names, which exist nowhere else.

## Connecting every device, everywhere

The Orange ISP router does not allow changing the DNS server it hands out. Tailscale is used instead: in the admin console, AdGuard is declared as the **Tailscale network's nameserver** (with "Override DNS servers"). Every connected device uses it, **at home and over 5G alike**.

The server and its containers do **not** use AdGuard (`--accept-dns=false`): a server must not depend on a service it hosts itself.

## Encrypted upstream DNS

AdGuard forwards all other queries to Quad9 and Cloudflare over **DNS over HTTPS**: neither the router nor the ISP can see which sites are visited.

## Private DNS zone (split-horizon)

A single DNS rewrite `*.maison.<domain>` → the proxy's Tailscale address is enough to make every internal address work. On the Internet, these names do not exist: nobody can discover or reach them. This is exactly the role of an **Azure Private DNS zone**.

## Limitations

A DNS blocker only sees names, not page content: it cannot block an ad served from the same name as the site itself (YouTube, sponsored posts). If the container stops, Tailscale devices lose name resolution: this is a **single point of failure**, accepted here and documented.
