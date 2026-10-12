# 4. Zero-trust remote access with Tailscale

Script: `scripts/03-tailscale-share.sh` (the same method is reused in every container)

## The problem

Opening ports on the ISP router to reach your services from outside means exposing them to the whole Internet, all the time. Bots scanning IP addresses would find a Proxmox web interface or an SMB share within hours.

## The solution: no open ports

**Tailscale** creates an encrypted private network (WireGuard) between my devices: iPhone, iPad, PC, the server and each of its containers. Every device authenticates with my account; connections are peer-to-peer, with nothing opened on the router.

This is the **zero trust** model: the network is not trusted (not even the home Wi-Fi); every device is authenticated.

## Implementation in an LXC container

By default, an unprivileged container has no access to the `/dev/net/tun` virtual network device that Tailscale needs. Two lines in its configuration allow it, and only it:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Each service then joins the network under its own name (`anto-jellyfin`, `anto-proxy`…), via `tailscale up --accept-dns=false`:

- `--accept-dns=false`: the servers keep the ISP router as their DNS, so they do not depend on AdGuard, which they host themselves;
- **key expiry disabled** for the server's machines, otherwise they would be disconnected every six months.

## Sharing without opening everything

To give a friend access to Jellyfin, **a single machine** (`anto-jellyfin`) is shared from the Tailscale admin console. The friend sees nothing else on the network: this is micro-segmentation.

## Cloud equivalent

Azure VPN Gateway or Azure Bastion for administration, private endpoints for the services: nothing is published on the Internet.
