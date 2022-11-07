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
