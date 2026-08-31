#!/usr/bin/env -S just --justfile
# Adapted from https://github.com/onedr0p/home-ops

set minimum-version := '1.55.0'

set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Bootstrap Recipes
# [group('Bootstrap')]
# mod bootstrap "bootstrap"

# Kube Recipes
[group('Kube')]
mod kube "kubernetes"

# Talos Recipes
[group('Talos')]
mod talos "talos"

# Tofu Recipes
[group('Tofu')]
mod tofu "tofu"

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# Render a Jinja template. talos/secrets.yaml is SOPS-decrypted and exposed under
# the `sops` key, so secrets are referenced as e.g. {{ sops.certs.os.crt }},
# {{ sops.cluster.id }}, {{ sops.secrets.bootstraptoken }}. talos/versions.yaml is
# merged in too, exposing {{ version.talos }} and {{ version.kubernetes }}.
[private]
template file *args:
    minijinja-cli -f yaml "{{ file }}" <(sops decrypt "{{ justfile_directory() }}/talos/secrets.yaml" | yq '{"sops": .}') "{{ justfile_directory() }}/talos/versions.yaml" {{ args }}
