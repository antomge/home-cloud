# 1. Hardware and the Proxmox hypervisor

## The hardware

| Component | Model | Role |
|---|---|---|
| CPU | Intel Core i5-9500 (6 cores, UHD 630 integrated graphics) | Compute + hardware video transcoding (Quick Sync) |
| Memory | 2 × 8 GB DDR4 (G.Skill Aegis), 2666 MHz dual channel | 16 GB shared between the containers |
| Motherboard | MSI H310M PRO-VDH PLUS | 4 SATA ports, HDMI output for the monitoring screen |
| System disk | Kingston A400 480 GB SSD | Proxmox + container disks |
| Data disk | WD Red Plus 4 TB (CMR) | Photos, movies, Immich data, backups |
| Copy disk | Seagate Barracuda 2 TB | Nightly copy of the photos |
| Network | TP-Link TL-SG605E switch (Gigabit, VLAN-capable) | 1 Gbit/s link to the ISP router |

The PC already existed: only the CPU, the WD Red and the switch were purchased (343.96 €). The WD Red Plus was chosen for its **CMR** technology (conventional magnetic recording), which is more reliable under sustained writes than the SMR used in entry-level drives.

**BIOS settings:** XMP memory profile, virtualization enabled, UEFI boot, and **automatic restart after a power outage**, which is essential for a server.

## Why a hypervisor?

Installing every service directly on a single Linux system means mixing their dependencies, their permissions and their failures. **Proxmox VE** (Debian + KVM + LXC) instead splits the machine into **isolated containers**, each with its own resources, like virtual machines in the cloud:

- a failed Jellyfin update does not affect the file share;
- each service has its own IP address, memory and number of cores;
- backups and restores are done container by container.

## LXC containers rather than virtual machines

An LXC container shares the host's kernel: it starts in two seconds and uses almost nothing when idle. All containers are **unprivileged**: a container's `root` maps to user `100000` on the host. Even if compromised, it has no rights on the server. This UID mapping is why the shared folders are owned by `101000:101000` (user `1000` inside the container).

## Installation

- Proxmox VE 9.2 on the SSD, ext4 + LVM file system; container storage is a *thin pool* (`local-lvm`).
- "enterprise" repository disabled, "no-subscription" repository enabled.
- High-availability services (`pve-ha-lrm`, `pve-ha-crm`) disabled: useless on a single node, and they constantly write to the SSD.
- Fixed address `192.168.1.33` reserved in the ISP router (static DHCP lease), hostname `serveur.home.arpa`.

## IP addressing plan

| Range | Use |
|---|---|
| `192.168.1.1` | ISP router (gateway) |
| `192.168.1.10–19` | Personal devices |
| `192.168.1.26–31` | Server containers (static leases) |
| `192.168.1.33` | Proxmox host |

All container addresses are **reserved in the ISP router**: the reverse proxy reaches the services by IP, so an address change would break it.
