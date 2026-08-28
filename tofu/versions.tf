# Adapted from https://github.com/onedr0p/home-ops
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }

  # State is encrypted at rest so tofu/terraform.tfstate can be committed (GitOps).
  # The real passphrase is injected at runtime through the TF_ENCRYPTION env var
  # by `just tofu ...` (see tofu/mod.just and tofu/README.md). The literal below
  # is a non-functional placeholder: `enforced = true` makes a bare `tofu` run
  # fail loudly rather than silently write plaintext state.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = "placeholder-passphrase-overridden-by-TF_ENCRYPTION-env"
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
