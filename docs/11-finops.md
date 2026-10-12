# 11. FinOps — measure, allocate, compare

Script: `scripts/11-install-finops.sh` (+ `12-add-dashboard-toggle.sh` for the screen button)
Code: `services/finops-releve.py`, `services/finops-azure.py`, `supervision/finops.html` · Assumptions: `configs/finops.json`

The FinOps approach comes down to three words: **inform** (know what you spend), **optimize**, **operate**. This page mainly covers the first one: making cost visible, per service, with an explicit method.

## 1. Measuring consumption

Every minute, `finops-releve.py` reads the **CPU energy counters** (Intel RAPL, `/sys/class/powercap/intel-rapl:0/energy_uj`), handling counter wrap-around. Power at the wall is then estimated:

```
P_wall = (measured P_cpu + 14 W other components) / 0.85 (power supply efficiency)
```

The 14 W (two hard drives, SSD, motherboard, memory, fans) is an **estimate**, written down explicitly in the assumptions and to be checked one day against a plug-in power meter. If RAPL is not available, CPU power is estimated from its load, and the page says so.

## 2. Allocating cost to services (showback)

Each minute of energy is split into two shares, each with its own **allocation key**:

| Share | Contents | Allocation key | Cloud analogy |
|---|---|---|---|
| **Variable** | CPU power above its idle level | CPU time actually used by each container (`/sys/fs/cgroup/lxc/<id>/cpu.stat`), with the remainder going to the host | Pay-as-you-go billing |
| **Fixed** | CPU idle power, disks, motherboard | Memory reserved by each container (the Proxmox host counts as 2 GB) | Reserved capacity, paid for even when unused |

Idle power is the lowest one-minute measurement over the last 7 days: the split becomes more accurate over time.

**Known limitation:** Jellyfin transcoding runs on the integrated GPU, whose energy is included in the CPU counter; the "CPU time" key slightly underestimates it.

## 3. The price

- **0.2001 €/kWh**: EDF Tarif Bleu, Base option (6 kVA), in effect since August 1, 2026.
- **The fixed subscription fee is not allocated**: it would be paid even without the server. A service is only charged for what it actually causes to vary (marginal cost).

## 4. Total cost of ownership

| Item | Treatment |
|---|---|
| Electricity | Average measured power × 730 h × price per kWh |
| Hardware bought for the project (343.96 €) | Amortized over 36 months → 9.55 €/month |
| Parts already owned (case, motherboard, memory, SSD, Barracuda) | **Sunk costs**: excluded from the calculation |
| Domain name | Annual price ÷ 12, to be entered in `configs/finops.json` |

## 5. Comparison with Azure

Every Monday, `finops-azure.py` queries the **public Azure Retail Prices API** (`prices.azure.com`, no account or key needed):

- **Standard_B4ms** VM (4 vCPUs, 16 GB), Linux, pay-as-you-go, France Central;
- **Standard HDD S50** disk (4 TB).

The filters exclude Windows, Spot and "low priority" prices. If the query fails, the last known prices are kept, with a warning.

### Result (October 2026)

| | Per month |
|---|---|
| Home Cloud: electricity (≈ 22 W at the wall) | ≈ 3.2 € |
| Home Cloud: amortized hardware | 9.55 € |
| **Home Cloud: total** | **≈ 13 €** |
| Azure: B4ms VM | 121.40 € |
| Azure: S50 disk | 138.75 € |
| **Azure: total** | **≈ 260 €** |

### Critical reading

- The comparison **favors Azure**: data egress (streaming), backups and an equivalent of hardware transcoding are not counted.
- It also favors the home server: no high availability, no off-site copy, and no time spent administering it.
- The optimization levers on Azure would be: a 1- or 3-year **reservation**, **cool Blob** storage for the photos instead of a provisioned disk, **shutting the VM down** at night, and rightsizing based on the measured load.

## The page

`https://tableau.maison.<domain>/finops`, also reachable from the server screen via the **COÛTS** ("costs") button:

- current power draw, cost for the day, the month (with projection) and the year;
- daily cost over 30 days, stacked by service, with tooltips;
- cost allocation table per service (current power, energy, cost, share, variable share);
- total cost of ownership versus the Azure equivalent;
- method and assumptions, spelled out in full.

Service colors come from a categorical palette validated for color blindness and for contrast on a dark background; every color is paired with a text label.
