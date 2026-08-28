# Adapted from https://github.com/onedr0p/home-ops
#
# The provider reads all connection settings from PROXMOX_VE_* environment
# variables, sourced from the SOPS-encrypted tofu/proxmox.sops.yaml by
# `just tofu ...`:
#
#   PROXMOX_VE_ENDPOINT   https://infra-vm.<domain>:8006/
#   PROXMOX_VE_API_TOKEN  <user>@pve!<token-id>=<uuid>
#   PROXMOX_VE_INSECURE   true to skip TLS verification of the PVE cert
#
# See https://registry.terraform.io/providers/bpg/proxmox/latest/docs
provider "proxmox" {
  # Everything comes from the environment; nothing to configure here.
  # SSH is only needed for a handful of operations (file uploads to directory
  # storages, some disk imports) that this configuration does not use.
}
