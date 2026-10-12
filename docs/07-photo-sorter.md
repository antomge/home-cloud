# 7. Automatic photo sorting

Script: `scripts/07-install-photo-sorter.sh` · Code: `services/tri-photos.py`

## The need

Drop photos in bulk from the iPhone or the PC, and find them filed by **year, then month**, without doing anything.

## How it works

Every 5 minutes (systemd timer), the photos and videos placed **at the root** of the `photos` folder are filed into `AAAA/MM - Mois/` (year/month, with French month names):

1. **capture date** read from the EXIF or QuickTime metadata with `exiftool` (a single invocation for all files);
2. otherwise, a date found **in the file name** (`IMG-20231005-WA0001.jpg`);
3. as a last resort, the modification date.

## Safeguards

| Risk | Protection |
|---|---|
| Moving a photo that is still being uploaded | A file modified less than 2 minutes ago is skipped until the next run |
| Losing a file | Nothing is ever deleted |
| Exact duplicate (same SHA-256 hash) | Moved to `_doublons/` (duplicates) |
| Two different photos with the same name | The second one gets a ` (1)` suffix |
| Disrupting existing albums | Subfolders are never touched |
| Two sorting runs at the same time | Lock (`flock`) |
| Slowing down other services | Lowest CPU and disk priority (`Nice=19`, `IOSchedulingClass=idle`) |

Every move is logged to `/var/log/tri-photos.log`, along with the source of the date used.

## Effect on the nightly copy

For `rsync`, a sorted photo "disappears" from the root and "appears" in a subfolder: the old location goes into the Barracuda recycle bin once (90 days). That is the temporary price of soft delete.
