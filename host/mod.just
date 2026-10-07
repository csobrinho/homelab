set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Binaries copied from mise (versions pinned in .mise/config.toml) into /usr/local/bin.
tools := "smartctl_exporter"

[doc('Install mise-pinned host tools into /usr/local/bin, then their systemd units')]
install-tools: && install-systemd
    mise install
    for tool in {{ tools }}; do
        sudo install -m 0755 "$(mise which "${tool}")" "/usr/local/bin/${tool}"
        just log info "Installed" tool "${tool}"
    done

[doc('Install, enable and (re)start the units in host/systemd')]
install-systemd:
    units=()
    for unit in "{{ source_directory() }}"/systemd/*; do
        sudo install -m 0644 "${unit}" "/etc/systemd/system/$(basename "${unit}")"
        units+=("$(basename "${unit}")")
    done
    sudo systemctl daemon-reload
    sudo systemctl enable "${units[@]}"
    # Restart so upgraded binaries and unit changes take effect.
    sudo systemctl restart "${units[@]}"
    just log info "Registered" units "${units[*]}"
