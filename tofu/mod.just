# Adapted from https://github.com/onedr0p/home-ops
set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Wrap every tofu invocation with:
#   - PROXMOX_VE_* creds, injected from tofu/proxmox.sops.yaml via `sops exec-env`
#   - TF_ENCRYPTION, built from the TOFU_STATE_PASSPHRASE in the same file
#   - TF_VAR_talos_schematic_id, rendered from talos/schematic.yaml.j2
[private]
exec +args:
    cd "{{ source_directory() }}"
    export TF_VAR_talos_schematic_id="${TF_VAR_talos_schematic_id:-$(just talos schematic-id)}"
    passphrase="$(sops decrypt --extract '["TOFU_STATE_PASSPHRASE"]' proxmox.sops.yaml)"
    export TF_ENCRYPTION="{\"key_provider\":{\"pbkdf2\":{\"state\":{\"passphrase\":\"${passphrase}\"}}}}"
    exec sops exec-env proxmox.sops.yaml "tofu {{ args }}"

[doc('Initialise the working directory / providers')]
init *args: (exec "init" args)

[doc('Show a plan')]
plan *args: (exec "plan" args)

[confirm('Apply changes to Proxmox [y|N] ?')]
[doc('Apply changes')]
apply *args: (exec "apply" args)

[confirm('DESTROY all three control-plane VMs [y|N] ?')]
[doc('Destroy everything this config manages')]
destroy *args: (exec "destroy" args)

[doc('Show outputs (add a name for one)')]
output *args: (exec "output" args)

[doc('Run any other tofu subcommand, e.g. `just tofu run state list`')]
run +args: (exec args)

[doc('Format *.tf in place')]
fmt:
    cd "{{ source_directory() }}" && tofu fmt -recursive

[doc('Validate the configuration (no credentials needed)')]
validate:
    cd "{{ source_directory() }}" && tofu validate
