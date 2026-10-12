# 8. Immich — photo gallery with content-based search (container 103)

Script: `scripts/08-create-immich.sh`

## Role

Find photos by their content ("beach", "cat", "birthday"), by face or by location, like in the iPhone Photos app, but on your own server. Search uses a **multilingual model**, so queries can be written in French.

## Architecture

Immich is distributed as several Docker containers (server, machine learning, PostgreSQL, Redis). They run **inside an unprivileged LXC container**, which requires the `nesting=1,keyctl=1` options.

| Component | Location | Why |
|---|---|---|
| Photos | `/mnt/wd/photos` mounted **read-only** | Immich reads the existing photo library without being able to modify it |
| Thumbnails, video previews, database backups | `/mnt/wd/immich` | Large, regenerable data: kept on the hard drive |
| PostgreSQL database | inside the container, on the SSD | Small, but under heavy random read/write load |
| Database password | `/opt/immich/.env`, generated at install time, readable by root | Never typed or displayed |

## Resources

At most 4 cores and 7 GB of memory: these are **limits**, not reservations. The initial analysis of the photo library (faces, content) is the most resource-hungry phase; it shows up clearly on the [FinOps page](11-finops.md), where Immich is the top consumer during that phase.

## Access

`https://immich.maison.<domain>` via the [HTTPS proxy](10-https-reverse-proxy.md), in the browser or the Immich mobile app.
