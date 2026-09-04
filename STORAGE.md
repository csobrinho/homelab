# Storage — EPYC host

Physical and logical storage layout for the EPYC host (ASRock Rack ROMED8-2T,
AMD EPYC 7003, Proxmox VE).

All NVMe is Samsung 990 PRO. Everything here should be reproducible from
Ansible — if you find yourself typing `zpool create` or `pvesm add` at a shell,
it belongs in the role instead.

> **Keep this doc current.** Every storage change is recorded here in the same
> change that makes it: a new pool or dataset, a PVC that gets its own storage, a
> disk claimed / reseated / its serial noted, a new TODO, and the decision and
> reasoning behind it. This file is the source of truth for host storage — if
> it's not written here, it didn't happen.

---

## PCIe topology

The EPYC IOD exposes four root-complex quadrants, one per bus base. This is the
primary framework for reasoning about which physical slot a device is in.

| Quadrant | Slots on it         | Notes                                  |
| -------- | ------------------- | -------------------------------------- |
| `00`     | PCIE2, PCIE5, M2_1  | PCIE2 and M2_1 share one 16-lane group |
| `40`     | M2_2, (PCIE4/PCIE6) | M2_2 has a dedicated x4                |
| `80`     | PCIE1, PCIE7        | clean split, no sharing                |
| `c0`     | PCIE3               |                                        |

`dmidecode -t slot` reports `ffff:` segments for the onboard M.2s and some
slots. The segment is a firmware placeholder and meaningless, but **the bus byte
in it is still correct** and is what identifies the quadrant.

### Storage domains

Named domains used throughout this doc and in pool-placement decisions:

| Domain | Physical          | Characteristics                                                                           |
| ------ | ----------------- | ----------------------------------------------------------------------------------------- |
| **A**  | PCIE1 (Adapter 1) | Dedicated x16, uncontended, coolest. Best domain.                                         |
| **B**  | PCIE2 (Adapter 2) | Shares its 16-lane group with M2_1 and SATA.                                              |
| **C**  | M2_2              | Dedicated x4, but sits under the GPUs — hottest drive in the box.                         |
| **D**  | M2_1              | Shares the root bridge with PCIE2 (same silicon lane group, not just board routing). Hot. |

Both bifurcation adapters are confirmed running **4×4×4×4**. All ports negotiate
**x4 Gen4 (16.0 GT/s)** with `max == current`.

### GPUs

Both RTX 5090s are passed through to VM 110 (`nvidia`):

- `01:00` — PCIE5, quadrant `00`
- `81:00` — PCIE7, quadrant `80`

---

## Current physical mapping

| Slot  | Adapter   | Domain | Root port | Endpoint  | Dev   | Serial            | Size | Assignment                                   |
| ----- | --------- | ------ | --------- | --------- | ----- | ----------------- | ---- | -------------------------------------------- |
| PCIE1 | Adapter 1 | A      | `80:03.1` | `82:00.0` | nvme0 | `S7KHNJ0WC60232B` | 2TB  | `vms` (single-disk)                          |
| PCIE1 | Adapter 1 | A      | `80:03.2` | `83:00.0` | nvme1 | `S7KHNU0X801652Y` | 2TB  | `data` (single-disk, live) — hosts `data/s3` |
| PCIE1 | Adapter 1 | A      | —         | —         | —     | _empty_           | —    | —                                            |
| PCIE1 | Adapter 1 | A      | —         | —         | —     | _empty_           | —    | —                                            |
| PCIE2 | Adapter 2 | B      | `00:03.1` | `02:00.0` | nvme3 | `S7KGNU0Y225237B` | 4TB  | `library_d1`                                 |
| PCIE2 | Adapter 2 | B      | `00:03.2` | `03:00.0` | nvme4 | `S7KGNU0Y701620B` | 4TB  | `library_d2`                                 |
| PCIE2 | Adapter 2 | B      | —         | —         | —     | _empty_           | —    | —                                            |
| PCIE2 | Adapter 2 | B      | —         | —         | —     | _empty_           | —    | —                                            |
| M2_1  | onboard   | D      | `00:03.5` | `04:00.0` | nvme5 | `S73WNU0XA42755B` | 2TB  | unassigned                                   |
| M2_2  | onboard   | C      | `40:01.1` | `41:00.0` | nvme2 | `S7KHNJ0X105718Z` | 2TB  | unassigned                                   |

> **Bay numbering within each adapter is not confirmed.** Root port function
> order (`.1`, `.2`, `.3`, `.4`) usually tracks physical bay order on
> bifurcation risers, but that's convention, not guarantee. Verify when
> populating the empty bays.

All drives on firmware `8B2QJXD7` (Dec 2025 — current). Wear is 0–2% across the
fleet.

---

## Target layout

| Slot        | Domain | Member       | Size | Status                                 |
| ----------- | ------ | ------------ | ---- | -------------------------------------- |
| PCIE1 bay 1 | A      | `db`-1       | 4TB  | not racked                             |
| PCIE1 bay 2 | A      | `models`-1   | 2TB  | not racked                             |
| PCIE1 bay 3 | A      | `models`-2   | 2TB  | not racked                             |
| PCIE1 bay 4 | A      | `vms`-1      | 2TB  | ✅ `S7KHNJ0WC60232B`                   |
| PCIE2 bay 1 | B      | `vms`-2      | 2TB  | awaiting RPi5 teardown                 |
| PCIE2 bay 2 | B      | `data`-1     | 2TB  | `S7KHNU0X801652Y` (currently on PCIE1) |
| PCIE2 bay 3 | B      | `data`-2     | 2TB  | awaiting RPi5 teardown                 |
| PCIE2 bay 4 | B      | `library_d1` | 4TB  | ✅ `S7KGNU0Y225237B`                   |
| M2_1        | D      | `library_d2` | 4TB  | `S7KGNU0Y701620B` (currently on PCIE2) |
| M2_2        | C      | `db`-2       | 4TB  | not racked                             |

### Placement rationale

- **`db` spans A + C** — both uncontended domains, so Postgres fsync latency
  never competes with media or backup traffic on a shared lane group. Only pool
  with `sync=standard`.
- **`models` sits entirely on A** — deliberate single-domain risk. Losing the
  pool means re-downloading weights; A gives the best sequential throughput for
  loading them.
- **`vms` splits A/B**, **`data` sits on B** — least latency-sensitive, so they
  absorb the shared-lane contention.
- **`library` takes the hot/shared domains (B, D)** — sequential media I/O
  tolerates both thermal throttling and lane contention far better than DB or
  model loads.

---

## Pools

### ZFS

| Pool     | Members        | ashift | recordsize | sync       | Other                          | Purpose                               |
| -------- | -------------- | ------ | ---------- | ---------- | ------------------------------ | ------------------------------------- |
| `vms`    | 2× 2TB (A + B) | 12     | — (zvols)  | `disabled` | `volblocksize=16K` via Proxmox | VM boot disks                         |
| `data`   | 2× 2TB (B)     | 12     | `128K`     | `disabled` | `xattr=sa`, `acltype=posix`    | General k8s PVCs; parents `data/s3`   |
| `db`     | 2× 4TB (A + C) | 12     | `16K`      | `standard` | `logbias=latency`              | Postgres/CNPG, SQLite, Home Assistant |
| `models` | 2× 2TB (A)     | 12     | `1M`       | `disabled` |                                | LLM weights                           |

Common to all: `compression=lz4`, `atime=off`, `autotrim=on` (pool), mirror vdev.

Create commands:

```bash
# vms
zpool create -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O atime=off -O sync=disabled \
  vms /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_<SERIAL>

# data
zpool create -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O atime=off -O sync=disabled \
  -O recordsize=128K -O xattr=sa -O acltype=posixacl \
  data /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_<SERIAL>

# data/s3 — object-storage child dataset (see "data/s3" below).
# Inherits sync=disabled / lz4 / atime=off / xattr=sa / acltype=posix from data.
zfs create data/s3
zfs set quota=250G data/s3

# db
zpool create -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O atime=off -O sync=standard -O logbias=latency \
  -O recordsize=16K -O xattr=sa -O acltype=posixacl \
  db mirror /dev/disk/by-id/... /dev/disk/by-id/...

# models
zpool create -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O atime=off -O sync=disabled \
  -O recordsize=1M \
  models mirror /dev/disk/by-id/... /dev/disk/by-id/...
```

**Always create pools against `/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_*`**,
never `/dev/nvmeXn1`. `zpool status` then shows the serial, which tells you
exactly which physical drive to pull when one faults. If a pool ever shows short
kernel names, fix it with:

```bash
zpool export <pool> && zpool import -d /dev/disk/by-id <pool>
```

> **`zpool attach`, never `zpool add`.** When the second mirror members free up,
> `attach` converts a single disk into a mirror. `add` appends a second
> top-level vdev and silently gives you a stripe with no redundancy.

### `data/s3` — object storage (RustFS)

Child dataset of `data`, **not its own pool** — there are no spare bays for one,
and object data isn't latency-sensitive enough to need an uncontended domain.

|                 |                                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Dataset         | `data/s3` — `quota=250G`; inherits `sync=disabled` / `lz4` / `atime=off` / `xattr=sa` / `acltype=posix` from `data`                  |
| Proxmox storage | `local-s3` — pool `data/s3`, `blocksize 64k`, `content images`, `sparse 1`, `nodes infra-vm`                                         |
| StorageClass    | `local-s3` — proxmox-csi, **xfs**, `reclaimPolicy: Retain`, `allowVolumeExpansion`. In `kubernetes/apps/proxmox-csi/overlays/prod/`. |
| Consumer        | one RustFS deployment, a single **200Gi RWO** PVC shared by every bucket                                                             |

**Why a dedicated dataset/storage, not just `local-data`:**

- **64k `volblocksize`** vs `local-data`'s 16k. RustFS objects and the Miroir
  migration backups are large and written whole; 16k quadruples metadata and
  hurts the compression ratio.
- **`quota=250G`** caps RustFS's share of the `data` pool, so a runaway bucket or
  a large backup set can't starve Prometheus / Valkey on the same disk. Expanding
  the PVC past ~200Gi means bumping the quota too.
- Independent snapshot lifecycle.

**Why one PVC for all buckets:** buckets are directories inside RustFS's data
dir, not separate volumes — there's no bucket→PVC mapping without running
separate RustFS instances. etcd snapshots + obsidian + Miroir backups are
similar-profile and low-stakes; isolate per consumer with access keys + bucket
quotas. Split a bucket into its own instance/PVC only if it diverges in size or
durability needs.

**Migration-window risk:** during the old→new cutover `data` is `sync=disabled`,
a single non-PLP SSD, no mirror yet. RustFS holds a _staging_ copy only — the old
cluster keeps the source until each restore is verified. Don't delete anything on
the old side early; watch pool usage (destination PVCs also land on `data`).

### mergerfs — `library`

Bulk media pool. 2× 4TB, **XFS** (not ZFS), pooled with mergerfs at
`/mnt/library`.

| Member | Serial            | Label        | Mountpoint        |
| ------ | ----------------- | ------------ | ----------------- |
| d1     | `S7KGNU0Y225237B` | `library_d1` | `/mnt/library_d1` |
| d2     | `S7KGNU0Y701620B` | `library_d2` | `/mnt/library_d2` |

Branch members are mounted from `/etc/fstab` **by label**, not by-id. See
[Identification conventions](#identification-conventions) for why.

---

## Proxmox storage

| ID           | Type    | Pool         | Content                      | Options                                                                                       |
| ------------ | ------- | ------------ | ---------------------------- | --------------------------------------------------------------------------------------------- |
| `local`      | dir     | —            | `vztmpl,import,iso,snippets` | boot mirror; cloud-init snippets. **No `backup`** — keep dumps off `rpool`.                   |
| `local-vms`  | zfspool | `vms`        | `images`                     | `blocksize 16k`, `sparse 1`                                                                   |
| `local-data` | zfspool | `data`       | `images`                     | `sparse 1`, `nodes infra-vm`                                                                  |
| `local-s3`   | zfspool | `data/s3`    | `images`                     | `blocksize 64k`, `sparse 1`, `nodes infra-vm` — see [data/s3](#datas3--object-storage-rustfs) |
| `local-zfs`  | zfspool | `rpool/data` | `rootdir`                    | boot mirror. **TODO:** still needs `--content ""` — nothing should land here.                 |

Naming follows Proxmox's own convention (`local`, `local-zfs`), so all
host-local storage sorts together in the UI and in `pvesm status`. Keep it
consistent: `local-vms`, `local-data`, `local-s3`, `local-db`, `local-models`.

```bash
pvesm add zfspool local-vms  --pool vms     --content images --blocksize 16k --sparse 1 --nodes infra-vm
pvesm add zfspool local-data --pool data    --content images                --sparse 1 --nodes infra-vm
pvesm add zfspool local-s3   --pool data/s3 --content images --blocksize 64k --sparse 1 --nodes infra-vm
pvesm set local     --content vztmpl,import,iso,snippets
pvesm set local-zfs --content ""
```

`blocksize` on `local-vms` / `local-s3` is where `volblocksize` gets set — it
isn't a pool property, so it has to come from the storage definition.

> Storage IDs can't be renamed in place. Disk paths are stored in VM configs as
> `storage-id:vm-NNN-disk-N`, so a rename means editing every VM config. Get the
> name right the first time.

---

## Identification conventions

Different layers use different identifiers, deliberately:

| Layer                   | Identifier       | Why                                                                                                              |
| ----------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| ZFS vdevs               | `by-id` (serial) | Identifies _hardware_. `zpool status` names the drive to physically pull.                                        |
| `/etc/fstab` (mergerfs) | `LABEL=`         | Identifies _filesystem_. Survives drive replacement — restore the fs with its label and the mount keeps working. |

Using by-id in fstab would mean that after a drive swap, `mount -a` silently
skips that branch and mergerfs serves a tree with a chunk missing — which looks
like data loss rather than a mount failure. Labels avoid that.

Label collisions aren't enforced by the kernel, but this is a single host where
every attached disk is known, so the risk is acceptable in exchange for fstab
entries that are readable in Git.

---

## Identifying a drive's physical location

Serials don't encode slot position. To rebuild the mapping:

```bash
# serial -> PCIe path
for c in /sys/class/nvme/nvme*; do
  bdf=$(basename "$(readlink -f "$c/device")")
  printf '%-7s %-18s %-24s %s\n' "$(basename $c)" "$(cat $c/serial)" \
    "$(cat $c/model)" "$(lspci -PP -s "$bdf" | awk '{print $1}')"
done

# firmware slot designations (bus byte is valid even when segment is ffff:)
dmidecode -t slot | grep -E 'Designation|Bus Address|Current Usage'

# link width/speed — reads from sysfs, no root needed
for b in 0000:80:03.1 0000:80:03.2 0000:00:03.1 0000:00:03.2 0000:00:03.5; do
  d=/sys/bus/pci/devices/$b
  printf '%s  max=x%s %s  cur=x%s %s\n' "$b" \
    "$(cat $d/max_link_width)" "$(cat $d/max_link_speed)" \
    "$(cat $d/current_link_width)" "$(cat $d/current_link_speed)"
done
```

How to read it:

1. Drives on the same bifurcation adapter appear as **sibling root ports under
   the same bridge device** (e.g. `00:03.1`, `00:03.2`). Two sibling groups =
   two adapters.
2. Match the root-port quadrant against `dmidecode` to get the slot name.
3. Singletons with no NVMe siblings are the onboard M.2s.
4. **Temperature corroborates**: M2_1 and M2_2 sit under the GPUs and run
   several degrees hotter than the adapter bays, even at idle.

`max_link_width` on the **bridge** (not the endpoint) answers the bifurcation
question: `x4` means 4×4×4×4, `x8` means the slot is in x8x8 and only two bays
are usable.

AGESA hides GPP bridges whose links never train, so a missing `80:03.3` /
`80:03.4` does **not** imply x8x8 — it just means those bays are empty.

`lspci -vv` needs root to read extended config space; without it the capability
block prints `<access denied>` and greps come back empty. The sysfs loop above
avoids that.

---

## Durability notes

`sync=disabled` on `vms`, `data` (inherited by `data/s3`), and `models` is safe
**only because of the UPS**. The 990 PRO has no power-loss-protection capacitors,
so an unexpected power cut with sync disabled loses whatever is in the drive's
write cache. If the UPS ever leaves the picture, this assumption breaks —
including for whatever migration data is staged in `data/s3` at the time.

`db` is the one pool where fsync means an actual transaction commit guarantee,
hence `sync=standard`. The more fundamental fix for sync durability is
enterprise drives with PLP (e.g. PM9A3); a SLOG is a latency optimization
layered on top of that, not a substitute for it.

---

## Outstanding

- [x] Create `data` pool on `S7KHNU0X801652Y`
- [x] Create `data/s3` dataset + `local-s3` storage + StorageClass
- [ ] Deploy RustFS + its 200Gi PVC on `local-s3`
- [ ] Clear `local-zfs` content types (`pvesm set local-zfs --content ""`) —
      still shows `content rootdir`
- [ ] Move storage definitions into Ansible, incl. the hand-applied
      `sync=disabled` / `autotrim=on` / `acltype=posix` on `data` and the
      `nvidia-user-data.yaml` snippet (the role currently only sets
      compression/atime/xattr, so a rebuild would regress these)
- [ ] Rack 2× 4TB for the `db` mirror
- [ ] Complete mirrors for `vms` and `data` after RPi5 teardown frees 2× 2TB —
      then `zpool attach data S7KHNU0X801652Y <partner>` (this also relocates
      `data`-1 PCIE1 → PCIE2 bay 2 per Target layout)
- [ ] Relocate `library_d2` (PCIE2 → M2_1) and reassign the two M.2 2TB drives
      to `models`

All relocations are power-down-and-reseat. ZFS imports by device ID and
mergerfs members mount by label, so nothing needs an export/import cycle.
