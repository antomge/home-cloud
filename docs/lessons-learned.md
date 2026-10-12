# Issues encountered and lessons learned

Every failure was a learning opportunity. Format: symptom → cause → fix → lesson.

### 1. "Failed to spawn container"
- **Cause:** the script had picked the first Debian 13 template in the list… the **arm64** version, on an x86 CPU.
- **Fix:** explicitly filter on `^debian-13-standard_.*_amd64`.
- **Lesson:** never take "the first result"; check the architecture.

### 2. A wrong disk serial number
- **Cause:** a typo in the SSD serial number, noted down by hand.
- **Fix:** read the serial number as Linux sees it (`lsblk -o NAME,SERIAL`).
- **Lesson:** identify disks by serial number, but copy it from the machine, never by hand. The script refuses to touch the system disk.

### 3. The dashboard cannot see Jellyfin (401 error)
- **Cause:** since Jellyfin 10.11, the legacy `X-Emby-Token` header is rejected by default.
- **Fix:** modern `Authorization: MediaBrowser Token="…"` header.
- **Lesson:** APIs evolve; test the response code rather than assume.

### 4. "Transcoding doesn't work"
- **Cause:** the test movie was 1.8 Mbit/s, below the 4 Mbit/s limit: Jellyfin had no reason to transcode.
- **Fix:** test with a 1 Mbit/s limit; Quick Sync confirmed, CPU about 78 % idle.
- **Lesson:** understand the decision rule before concluding that something is broken.

### 5. Streamyfin stops working over 5G
- **Cause:** the machines had been renamed in the Tailscale admin console, so their MagicDNS names had changed.
- **Fix:** update the address in the app.
- **Lesson:** a name is a dependency; changing it breaks whatever relies on it. Hence the value, later on, of stable names behind a proxy.

### 6. SSD health: 39 % or 61 %?
- **Cause:** SMART attribute 231 on the Kingston A400 is not interpreted the same way by every tool.
- **Fix:** measure the **data written** (attribute 241) relative to the **rated endurance** (160 TB written). "À surveiller" ("watch") threshold at 50 %.
- **Lesson:** prefer an objective, documented indicator over an ambiguous "vendor" value.

### 7. A pasted script that gets scrambled
- **Cause:** the Proxmox web console (in the browser) mixes up very long lines during a large paste.
- **Fix:** transfer large scripts with `scp`, and keep lines short in the ones that are pasted.
- **Lesson:** transfer files; don't paste 800 lines into a terminal.

### 8. The dashboard returns 404 behind the proxy
- **Cause:** `tailscale serve` only answers requests addressed to **its own name**; Caddy was forwarding the name requested by the browser.
- **Fix:** `header_up Host <server's full MagicDNS name>` in Caddy.
- **Lesson:** when chaining two proxies, the `Host` header is part of the contract.

### 9. IP addresses that could change
- **Finding:** the proxy reaches the services by their local IP; a new address handed out by the ISP router would break it.
- **Fix:** static DHCP leases for every container, and an address range reserved for the server.
- **Lesson:** a service that others depend on must have a stable address.
