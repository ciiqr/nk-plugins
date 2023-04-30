#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

declare nix_config='
experimental-features = nix-command flakes
warn-dirty = false
'

nix_cli::_provision_nix() {
    # TODO: handle updates
    if ! type nix >/dev/null 2>&1; then
        # install
        NIX_EXTRA_CONF="$nix_config" \
            sh <(curl -L https://nixos.org/nix/install) \
            --daemon \
            --no-modify-profile \
            || return "$?"
        changed='true'
        action='install'
    fi
}

nix_cli::_provision_gc() {
    # `nix-store` on path
    if type nix-store >/dev/null 2>&1; then
        declare dead_store_output
        dead_store_output="$(nix-store --gc --print-dead --quiet)" || return "$(nk::error "$?" 'failed to list dead paths')"
        declare -a dead_store_paths
        while read -r file; do
            dead_store_paths+=("$file")
        done <<< "$dead_store_output"

        # at least one dead path
        if [[ "${#dead_store_paths[@]}" -gt 0 ]]; then
            declare disk_usage
            disk_usage="$(du -mc "${dead_store_paths[@]}" | tail -n1 | awk '{print $1}')" \
                || return "$(nk::error "$?" 'failed to get disk usage of dead paths')"

            # disk usage > 1G
            if (( disk_usage > 1000 )); then
                nix-store --gc || return "$?"
                changed='true'
            fi
        fi
    fi
}

declare action='install'
declare status='success'
declare changed='false'
declare output=''
if ! nk::run_for_output output nix_cli::_provision_nix; then
    status='failed'
fi

nk::log_result \
    "$status" \
    "$changed" \
    "${action} package nix" \
    "$output"

declare status='success'
declare changed='false'
declare output=''
if ! nk::run_for_output output nix_cli::_provision_gc; then
    status='failed'
fi

nk::log_result \
    "$status" \
    "$changed" \
    'nix store clean' \
    "$output"
