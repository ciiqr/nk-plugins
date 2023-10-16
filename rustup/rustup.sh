#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

rustup::provision_rustup() {
    if ! type 'rustup' >/dev/null 2>&1; then
        action='install'

        # download init script
        declare rustup_init_script
        rustup_init_script="$(curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs)" \
            || return "$(nk::error "$?" 'failed downloading rustup installer')"

        # install rustup
        sh -s - -y --no-modify-path <<< "$rustup_init_script" \
            || return "$(nk::error "$?" 'failed installing rustup cli')"
        changed='true'
    else
        action='update'

        declare rustup_check_output
        rustup_check_output="$(rustup check)" \
            || return "$(nk::error "$?" 'failed checking for updates')"

        if [[ "$rustup_check_output" == *'Update available'* ]]; then
            rustup update \
                || return "$(nk::error "$?" 'failed updating')"
            changed='true'
        fi
    fi
}

rustup::provision() {
    # install rustup
    declare action='install'
    declare status='success'
    declare changed='false'
    declare output=''
    if ! nk::run_for_output output rustup::provision_rustup; then
        status='failed'
    fi
    nk::log_result \
        "$status" \
        "$changed" \
        "${action} rustup" \
        "$output"
}

case "$1" in
    provision)
        rustup::provision "${@:2}"
        ;;
    *)
        echo "rustup: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
