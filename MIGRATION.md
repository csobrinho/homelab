# k3s → Talos migration

Moving the homelab off the old k3s cluster onto Talos Linux. Work happens on the
`migration` branch.

## Target

| | |
| --- | --- |
| Networks | nodes/infra `10.10.2.0/24`; VIPs `10.10.10.0/24` (BGP-routed) |
| Control plane | 3 dedicated VMs `infra1/2/3` on Proxmox `infra-vm`, `10.10.2.11-13/24` |
| Workers | more Proxmox VMs on the EPYC host, and RPi5 nodes (**arm64**) — all on `10.10.2.0/24` |
| Endpoint | `infra-k8s` round-robin DNS + KubePrism; API VIP via Cilium BGP later |
| CNI | Cilium, native routing + BGP peering with the UniFi gw (AS65000 @ `10.10.2.1`) |
| GitOps | ArgoCD app-of-apps from `bootstrap/` |
| Provisioning | `tofu/` (bpg/proxmox); Talos config `talos/` via `just talos` |
| Secrets | SOPS + age (`talos/secrets.yaml`, `tofu/proxmox.sops.yaml`) |

## Status

- [x] `tofu/` provisions the 3 CP VMs (q35/OVMF, 4 vCPU / 8 GiB, 64 GiB zvol on
      `local-vms`, MAC `52:54:00:0a:02:1x`, watchdog, guest-agent)
- [x] Talos config VM-adapted (static addressing, virtio NIC alias, disk selector,
      SOPS-rendered secrets, endpoint `infra-k8s`)
- [x] Toolchain + Talos pinned to `v1.14.0-rc.2`
- [x] Cluster bootstrapped — etcd up, k8s `v1.37.0`
- [x] **A.** Cilium deployed — nodes Ready
- [ ] **A'.** Delete the dead bare-metal config from `talos/cluster.yaml.j2`
- [ ] **B.** Drop the `kube-api-proxy` socat (LB Service + EndpointSlice, or DNS-only)
- [ ] **C.** Bootstrap CRDs (wave 0)
- [ ] **D.** Deploy CoreDNS
- [ ] **E.** Deploy ArgoCD → hand off to `bootstrap/root-app`
- [ ] Workers (EPYC VMs + RPi5 arm64) + storage
- [ ] Cut over DNS / retire the old cluster

## Plan

### A. Cilium — done

Deployed via `kustomize build --enable-helm apps/cilium/overlays/prod`. Nodes Ready.
Remaining: delete the stale vendored `apps/cilium/overlays/prod/charts/cilium-1.20.0/`
(chart is pulled from the repo). Verify `cilium bgp peers` established with `10.10.2.1`.

### A'. Delete dead bare-metal config

No Meteor Lake nodes — workers are EPYC VMs (virtio, like the CP) and RPi5 (arm64).
Remove from `talos/cluster.yaml.j2` (all `# TODO`): the `atlantic` bond / VLAN link
docs, `RawVolumeConfig miroir-slow`, and the `drbd` / `drbd_transport_tcp` /
`dm_thin_pool` / `nbd` `KernelModuleConfig` docs. RPi5 arm64 workers will need a
`nodes/workers/<node>.schematic.yaml.j2` override for the arm64 image.

### B. Drop the socat API proxy

The `10.10.10.x` API VIP can't be a Talos `Layer2VIPConfig` — that needs the VIP in
the node interface's own subnet, and VIPs are on `10.10.10.0/24` (routed to the
cluster via Cilium BGP). Options:

1. **DNS-only** — keep `infra-k8s` round-robin at `10.10.2.11-13`; KubePrism gives
   in-cluster HA. Delete `kube-api-proxy.yaml` + its LB pool, no replacement.
2. **LB Service + manual EndpointSlice** — a `LoadBalancer` Service (VIP from the
   `10.10.10.0/24` pool, BGP-advertised) with a hand-maintained `EndpointSlice`
   pointing at `10.10.2.11-13:6443`. Removes the socat container; the apiserver is
   the backend directly.

Either way `certExtraSANs` already covers `infra-k8s` + the node IPs; add the VIP
address to the SANs if option 2's VIP becomes the `controlPlane.endpoint`.

### C. Bootstrap CRDs (wave 0)

CRDs that apps assume exist before ArgoCD reconciles — install first:

- Prometheus-operator (`ServiceMonitor`, `PrometheusRule`, …) — Cilium sets
  `serviceMonitor.trustCRDsExist: true`
- gateway-api / external-secrets / snapshot-controller / etc. as the app set needs

Cilium ships its own CRDs (`includeCRDs: true`), so A doesn't depend on this.

### D. CoreDNS

Disabled in Talos (`KubeCoreDNSConfig enabled: false`) to self-manage. Deploy the
`coredns/coredns` chart. (Or flip `enabled: true` for Talos-managed.) With B done
it's off the API-endpoint critical path, but everything else needs it.

### E. ArgoCD

Install ArgoCD, then:

```sh
kubectl apply -f bootstrap/root-app/application.yaml
```

App-of-apps from `bootstrap/apps` takes over — including adopting Cilium and CoreDNS.

## Later — workers + storage

- **EPYC VM workers**: `tofu/` — add worker entries (same bpg pattern; the CD-ROM
  ISO / schematic are shared with the CP). Create `talos/workers.yaml.j2`
  (`machine.type: worker`, `ca` crt-only) + `talos/nodes/workers/<node>.yaml.j2`.
  All on `10.10.2.0/24`, so `autoDirectNodeRoutes` keeps working fleet-wide — no
  PodCIDR BGP advertisement needed.
- **RPi5 workers** (arm64): not tofu — flash the Talos arm64 SBC image. Needs an
  arm64 schematic (`nodes/workers/<node>.schematic.yaml.j2`) and arm64-safe
  workload scheduling (`kubernetes.io/arch` nodeAffinity or multi-arch images).
- Storage: rook-ceph (and/or `miroir` DRBD9) once there are worker nodes to host it.

## Bring-up reference

- **Proxmox token** (`tofu@pve!controlplane`, role `TofuProvision`) needs
  `SDN.Use` on PVE 9 for bridge assignment (plain bridges are in the
  `localnetwork` SDN zone). Add any further privileges hit during `tofu apply`
  to `tofu/README.md`.
- **First `apply-config`** is `--insecure` to the node's *maintenance* DHCP IP
  (`10.10.2.121-123`); the static `.11-.13` only exists after the config installs
  and the node reboots, after which the API needs mTLS (`talosconfig`).
- **talosconfig:**
  ```sh
  sops decrypt talos/secrets.yaml > /tmp/s.yaml
  talosctl gen config main https://infra-k8s:6443 --with-secrets /tmp/s.yaml \
    --talos-version v1.14.0-rc.2 --output-types talosconfig -o talosconfig
  rm /tmp/s.yaml
  talosctl config endpoint 10.10.2.11 10.10.2.12 10.10.2.13
  ```
- **Disk selector** must exclude the ISO's loop/cdrom:
  `!disk.readonly && !disk.cdrom && disk.size > 10u * GB`.
- **Cilium on Talos** needs `cgroup.autoMount.enabled: false`, a capability set
  without `SYS_MODULE`, and `socketLB.hostNamespaceOnly: true` (for Talos
  `forwardKubeDNSToHost`).
- **Full shutdown:** `just talos shutdown-cluster`. Never Proxmox "Stop" — use
  "Shutdown" (ACPI) or the recipe.
- **`tofu/terraform.tfstate`** is committed, encrypted (OpenTofu native
  `aes_gcm`/`pbkdf2`, passphrase in `proxmox.sops.yaml`). Re-commit after every
  `just tofu apply`. Losing the age key = unrecoverable state and secrets.
