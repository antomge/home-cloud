# 2. Storage and backups

## Preparing the disks — `scripts/01-prepare-disks.sh`

- Disks are identified **by serial number**, never by their `/dev/sdX` name, which can change from one boot to the next. The script refuses to continue if a target disk is the system disk or has a mounted partition, and asks you to type `YES` before erasing anything.
- GPT partition table, a single partition, **ext4 with `-m 0`**: the 5 % reserved for root (200 GB on 4 TB) makes no sense on a data disk.
- Mounted in `/etc/fstab` **by UUID**, with `noatime` (no write on every read) and `nofail` (the server still boots if a disk is missing).

| Disk | Mount point | Contents |
|---|---|---|
| WD Red Plus 4 TB | `/mnt/wd` | `photos/`, `films/`, `papiers/`, `immich/`, `sauvegardes/`, `transcodage-jellyfin/` |
| Barracuda 2 TB | `/mnt/barracuda` | `copie-photos/` and `copie-papiers/` (each with `actuel` and `corbeille`, i.e. current and recycle bin) |

(Folder names are in French: `films` = movies, `papiers` = personal documents, `sauvegardes` = backups, `transcodage-jellyfin` = Jellyfin transcoding.)

## How the containers see the data

The WD folders are **bind-mounted into the containers** (`mp0`, `mp1`… in `configs/lxc/`). The same file is therefore visible to several services, with different permissions:

| Folder | partage | jellyfin | immich |
|---|---|---|---|
| `photos` | read / write | — | **read-only** |
| `films` | read / write | **read-only** | — |

Jellyfin and Immich can neither modify nor delete your files: this is **least privilege** applied to storage.

## Two layers of protection

### 1. Container snapshots (Proxmox)

Job `sauvegarde-nuit` (`configs/jobs.cfg`): every night at **2 a.m.**, all containers are backed up in *snapshot* mode (without stopping them), compressed with zstd, to the `sauvegardes` storage on the WD.
Retention: **7 daily + 4 weekly backups**.

These protect the containers' **system** (configuration, Immich database), not the photos and movies, which live on bind mounts.

### 2. Photo copy with recycle bin — `services/copie-photos.sh`

Every night at **3 a.m.**, `rsync` copies `/mnt/wd/photos` and `/mnt/wd/papiers` to the Barracuda:

- a file deleted or modified on the WD is not lost: the old version is moved to `corbeille/<date>/` and kept there for **90 days** (the equivalent of Azure Storage *soft delete*);
- **disaster safeguard**: if the source folder is empty while the copy contains files (badly mounted disk, mass deletion), the run is **aborted** instead of wiping the copy;
- the result is written to a status file shown on the monitoring screen.

Installation (units in `services/systemd/`):

```bash
install -m 755 services/copie-photos.sh /usr/local/sbin/
cp services/systemd/copie-photos.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now copie-photos.timer
```

## RPO, RTO and the 3-2-1 rule

- **RPO** (maximum data loss): 24 h for the photos and the containers.
- **RTO** (time to restore service): a few minutes to restore a container from the Proxmox web interface.
- **3-2-1**: 3 copies, on 2 types of media, 1 of them off-site. Here: 2 copies of the photos and documents, on 2 disks, **but none off-site**. This is the project's main limitation, and a deliberate one.

## Disk health monitoring

`services/releve-smart.py` reads the SMART attributes every 10 minutes. For the SSD, the chosen indicator is the **amount of data written relative to the rated endurance** (160 TB for the Kingston A400), which is more reliable than this model's "life remaining" attribute, whose interpretation varies between tools (see [lessons learned](lessons-learned.md)).
