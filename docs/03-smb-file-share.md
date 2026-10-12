# 3. SMB file share — container 101 "partage"

Script: `scripts/02-create-share.sh` · Configuration: `configs/containers/smb.conf`

## Role

Upload and retrieve photos, movies and personal documents from a Windows PC (`\\192.168.1.26\photos` at home) or from the iPhone Files app. When away from home, the container's Tailscale name is used instead of its IP address.

## Configuration choices

| Setting | Why |
|---|---|
| `server min protocol = SMB3` | SMB1 and SMB2 are obsolete and vulnerable; remote traffic is encrypted by Tailscale anyway |
| `map to guest = never` | No anonymous access |
| `disable netbios = yes`, port 445 only | Fewer exposed services, smaller attack surface |
| `valid users = anto` | One named account per share, password entered with hidden input during installation |
| `vfs objects = fruit streams_xattr` | Compatibility with the iOS Files app and macOS |

## The "papiers" share (personal documents)

Added with `scripts/14-add-papers-share.sh` for ID documents, official attestations and certificates:

- folder with mode `700`: only `anto` can access it, and it is mounted in **no** other container (neither Jellyfin nor Immich);
- `server smb encrypt = desired`: SMB3 encryption whenever the device supports it, even on the local network;
- `veto files`: executables and scripts (`.exe`, `.bat`, `.js`, `.ps1`…) are rejected;
- copied every night to the Barracuda, with a 90-day recycle bin.

Limitation: the files are not encrypted on the disk itself; if the server were stolen, they would be exposed.

## Permissions

The folders are owned by `101000:101000` on the host, i.e. by user `anto` (UID 1000) **inside** the unprivileged container. The container can only access the three mounted folders, nothing else on the server.

## Resources

1 core, 512 MB of memory, 4 GB of disk: Samba is very lightweight. That is also what makes it cheap on the [FinOps page](11-finops.md).

## Cloud equivalent

Azure Files (managed SMB share), reached through a private endpoint rather than exposed to the Internet.
