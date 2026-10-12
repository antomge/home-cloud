# 5. Jellyfin and hardware transcoding — container 102

Script: `scripts/04-create-jellyfin.sh`

## Role

Watch movies anywhere: on the TV, the PC, or the iPhone with the Streamyfin app, including over 5G via Tailscale.

## Hardware transcoding (Intel Quick Sync)

When the connection is too slow for the original file (on 4G, for example), Jellyfin **re-encodes** the video on the fly at a lower quality. Done by the CPU, this is very heavy; done by the UHD 630 integrated graphics (Quick Sync), it is almost free.

To give the GPU to the container, only the render device is passed through, with the container's `render` group:

```
dev0: /dev/dri/renderD128,gid=992
```

Result verified during a transcode: H.264/HEVC decoding and encoding on the GPU, CPU about 78 % idle.

## Configuration choices

| Setting | Why |
|---|---|
| Movies mounted **read-only** (`ro=1`) | Jellyfin cannot modify or delete the media library |
| Transcoding folder on the WD (`/mnt/wd/transcodage-jellyfin`) | Temporary transcoding files wear out the SSD, so they are sent to the hard drive |
| 4 cores, 3 GB of memory | Headroom for several simultaneous streams |
| Official `repo.jellyfin.org` repository | `jellyfin-ffmpeg` includes the Intel iHD driver |

The transcoding folder no longer appears in the Jellyfin 10.12 web interface: it is set directly in `/etc/jellyfin/encoding.xml` (`TranscodingTempPath`).

## Quality on the go

On 4G, the streaming bitrate is capped at around 720p and about 4 Mbit/s (≈ 1.8 GB per hour), to spare a 250 GB mobile data plan.

## Access

`https://jellyfin.maison.<domain>` via the [HTTPS proxy](10-https-reverse-proxy.md), from any Tailscale device.
