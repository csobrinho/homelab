# Tofu

[OpenTofu](https://opentofu.org) configuration that provisions the Talos VMs on
the Proxmox node `infra-vm`, using the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
provider:

- **Control plane** — `infra1/2/3` (`var.nodes`), 4 vCPU / 8 GiB each.
- **Workers** — `var.workers`, all `infra4+`: `infra4` is the GPU node (12 vCPU /
  64 GiB) with both RTX 5090s passed through — it replaces the old k3s VM 110
  (decommission that by hand — not managed here); `infra5/6/7` are general
  compute (24 vCPU / 96 GiB each).

Scope is deliberately small: **VMs only**. Talos machine configuration is rendered
and applied separately with `just talos apply-node <node>` once a VM is up.

## Failure domains

Every VM - control plane and workers - runs on the single Proxmox host
`infra-vm`. The 3-node control plane protects against VM-, Talos- and
etcd-disk-level failure, but **not host failure**: an `infra-vm` outage takes the
whole cluster down and loses etcd quorum. No second Proxmox host is planned. The
only route to a real second failure domain is the RPi5 nodes (arm64) added later -
one could carry a control-plane member if etcd host-redundancy becomes a
requirement.

Splitting compute across `infra5/6/7` rather than one big VM buys node-at-a-time
Talos upgrades, real `PodTopologySpread`, and 3 hosts for rook-ceph's CRUSH map -
not hardware fault tolerance.

## Layout

| Path                       | Purpose                                                          |
| -------------------------- | --------------------------------------------------------------- |
| `versions.tf`              | Provider + `required_version` pins, state encryption block       |
| `providers.tf`             | Proxmox provider (all connection settings come from the env)     |
| `variables.tf`             | Inputs (`nodes` / `workers` come from `terraform.tfvars`; rest default) |
| `main.tf`                  | ISO download + one `node` VM resource over a merged `var.nodes` + `var.workers` map |
| `outputs.tf`               | VM IDs and NIC MACs, split `control_plane` / `workers` by role   |
| `terraform.tfvars`         | Non-secret, environment-specific values (committed)              |
| `proxmox.sops.yaml`        | SOPS-encrypted `PROXMOX_VE_*` + state passphrase (committed)     |
| `terraform.tfstate`        | Encrypted state, committed (GitOps)                              |
| `mod.just`                 | `just tofu ...` recipes                                          |

## Secrets & state

- **Provider credentials** live in `proxmox.sops.yaml`, encrypted to the age keys
  in the repo `.sops.yaml`. `just tofu ...` injects them via `sops exec-env`, so
  no plaintext ever hits disk. On a fresh clone, recreate it with the keys the
  provider (`providers.tf`) and `mod.just` expect:

  ```sh
  sops edit proxmox.sops.yaml        # sops creates + encrypts on save
  ```

  | Key                     | Value                                              |
  | ----------------------- | -------------------------------------------------- |
  | `PROXMOX_VE_ENDPOINT`   | `https://<pve-host>:8006/`                          |
  | `PROXMOX_VE_API_TOKEN`  | `<user>@<realm>!<token-id>=<uuid>`                  |
  | `PROXMOX_VE_INSECURE`   | `"true"` to skip TLS verification of the PVE cert   |
  | `TOFU_STATE_PASSPHRASE` | long random string; encrypts `terraform.tfstate`   |

- **State is committed** to git. OpenTofu's native state encryption (`aes_gcm`
  keyed by a PBKDF2 passphrase) keeps `terraform.tfstate` unreadable at rest. The
  passphrase is `TOFU_STATE_PASSPHRASE` inside `proxmox.sops.yaml`; `mod.just`
  turns it into `TF_ENCRYPTION` at runtime. Running bare `tofu` without that env
  var fails on purpose - always go through `just tofu ...`.

## Talos image

The boot ISO is pulled straight onto Proxmox storage from the
[Image Factory](https://factory.talos.dev). Two files in `talos/` stay the single
source of truth; `just tofu ...` injects both as `TF_VAR_*`:

- `schematic.yaml.j2` -> `talos_schematic_id` (via `just talos schematic-id`):
  system extensions and kernel args.
- `versions.yaml` (`.version.talos`) -> `talos_version`: the release tag. The same
  file drives the installer image and kubelet image in `talos/cluster.yaml.j2`,
  so the ISO and the installed system never diverge. Bump it there.

The ISO filename embeds the version, so bumping `talos_version` replaces the
download resource - the old ISO is deleted, the new one fetched. If you bump it
while `attach_iso` is still `true` and the VMs are running, detach first (set
`attach_iso = false`, apply) or Proxmox will refuse to delete the in-use ISO.
Past bring-up this is moot: `attach_iso = false` and OS upgrades go through
`just talos upgrade-node`.

> If `just talos schematic-id` is not reachable as a cross-module call in your
> `just` version, drop `[private]` from that recipe in `talos/mod.just`, or set
> `talos_schematic_id` directly in `terraform.tfvars`.

## Usage

```sh
just tofu init
just tofu plan
just tofu apply
just tofu output control_plane      # grab the CP NIC MACs for DHCP reservations
just tofu output workers            # same, for infra4-7
just tofu run state list            # any other subcommand
just tofu destroy
```

### Adding the workers

`var.workers` is empty by default; `infra4` (GPU) + `infra5/6/7` are set in
`terraform.tfvars`. Each key needs a matching `talos/nodes/workers/<key>.yaml.j2`.
Then `just tofu apply`, add DHCP reservations from `just tofu output workers`, and
`just talos apply-node infra5` (etc.) — no `bootstrap`, workers just join.

> **Nodes with a `.schematic.yaml.j2` override (e.g. `infra4`):** the boot ISO
> only carries the *base* schematic; extensions come from the per-node
> `installer.image`. If the first install lands from the ISO's own installer the
> extension is missing (`talosctl get extensions` empty, kmod modprobe fails).
> Fix / verify right after join:
> ```sh
> talosctl -n <ip> -e <ip> get extensions
> talosctl -n <ip> -e <ip> upgrade --image "$(just talos machine-image <node>)"   # if missing
> ```
> (`-e <ip>` talks to the node directly — a not-yet-joined node can't be reached
> through a control-plane endpoint: `no request forwarding`.)

**GPU passthrough (`infra4`)** — the two RTX 5090s are at `0000:01:00` and
`0000:81:00` (already in `terraform.tfvars`). Before `apply`, on the Proxmox host:

1. Enable IOMMU + "above 4G decoding" / Resizable BAR in the host BIOS, and
   `amd_iommu=on iommu=pt` on the kernel cmdline.
2. Bind all four functions (`01:00.0/.1`, `81:00.0/.1`) to `vfio-pci`, not the
   host `nvidia`/`nouveau`/`snd_hda_intel` drivers — verify with
   `lspci -nnk -d 10de:` (`Kernel driver in use: vfio-pci`).
3. Check each GPU + its audio sit alone in their IOMMU group; if `01:00` is the
   host's boot framebuffer, detach it (`initcall_blacklist=sysfb_init` or
   `video=efifb:off,vesafb:off`).
4. **As `root@pam`**, create two datacenter PCI resource mappings (Datacenter →
   Resource Mappings → Add → PCI, "All Functions" checked):
   `gpu0` → `0000:01:00`, `gpu1` → `0000:81:00`. `terraform.tfvars` references
   these by name. A raw `hostpci` path (`id`) can only be set by `root@pam` over
   the API — the `tofu@pve!controlplane` token gets *"only root can set
   'hostpciN' config for non-mapped devices"* — but a **mapping** just needs
   `Mapping.Use`:
   ```sh
   pveum role modify TofuProvision --privs Mapping.Use,Mapping.Audit --append
   ```
5. If the guest hits code 43 / black screen, dump the card vBIOS and set
   `rom_file` on the `hostpci` entry.

`infra4` then boots the shared ISO but installs the NVIDIA schematic
(`talos/nodes/workers/infra4.schematic.yaml.j2`) via its per-node installer
image — nothing GPU-specific is needed here beyond the `hostpci` block.

### Migrating off the old split resources

`main.tf` used to have separate `proxmox_virtual_environment_vm.controlplane`
and `.worker` resources; it is now one `.node` resource over a merged map. The
`moved {}` blocks in `main.tf` renumber the existing `infra1-3` state on the
next `just tofu apply` — no VM is recreated. (Equivalently, one-time:
`just tofu run state mv 'proxmox_virtual_environment_vm.controlplane["infra1"]' 'proxmox_virtual_environment_vm.node["infra1"]'`,
×3.) Delete the `moved {}` blocks once applied.

### First bring-up

1. `just tofu apply` - creates the ISO download + three stopped/started VMs.
2. Add DHCP reservations for the MACs from `just tofu output control_plane` so
   each node lands on a stable address in `10.10.2.0/24`.
3. Boot order is `scsi0` then the ISO, so the empty disk falls through to the
   installer on first boot; Talos installs to `scsi0` and reboots off it.
4. `just talos apply-node infra1` (then `infra2`, `infra3`) to push machine config.
5. Bootstrap etcd on the first node: `talosctl -n infra1 bootstrap`.
6. Bring up the workers (see below) while `attach_iso` is still `true`.
7. Once every node is installed and healthy, set `attach_iso = false` in
   `terraform.tfvars` and `just tofu apply` - this deletes the ISO and detaches
   the CD-ROM, so later `talos/versions.yaml` bumps don't churn the VMs. OS
   upgrades from here on are `just talos upgrade-node <node>`.

## Talos machine config

Not managed here. `talos/README.md` covers how per-node configs are rendered and
applied; `MIGRATION.md` tracks the k3s -> Talos plan and current state (node
subnet, endpoint, DNS, storage direction, remaining `# TODO` items).

The install `diskSelector` in `talos/cluster.yaml.j2` is
`!disk.readonly && !disk.cdrom && disk.size > 10u * GB` - it picks the single
writable virtio disk and skips the read-only ISO loop/cdrom devices.
