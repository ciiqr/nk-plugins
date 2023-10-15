#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

hostname::_provision_macos() {
    declare current_host_name
    current_host_name="$(scutil --get 'HostName')"
    if [[ "$current_host_name" != "$hostname" ]]; then
        sudo scutil --set 'HostName' "$hostname" \
            || return "$(nk::error "$?" 'failed setting HostName')"
        changed='true'
    fi

    declare current_local_host_name
    current_local_host_name="$(scutil --get 'LocalHostName')"
    if [[ "$current_local_host_name" != "$hostname" ]]; then
        sudo scutil --set 'LocalHostName' "$hostname" \
            || return "$(nk::error "$?" 'failed setting LocalHostName')"
        changed='true'
    fi

    declare current_computer_name
    current_computer_name="$(scutil --get 'ComputerName')"
    if [[ "$current_computer_name" != "$hostname" ]]; then
        sudo scutil --set 'ComputerName' "$hostname" \
            || return "$(nk::error "$?" 'failed setting ComputerName')"
        changed='true'
    fi

    if [[ "$changed" == 'true' ]]; then
        dscacheutil -flushcache \
            || return "$(nk::error "$?" 'failed flushing ds cache')"
    fi
}

hostname::_provision_linux() {
    declare current_hostname
    current_hostname="$(hostnamectl hostname)"

    if [[ "$current_hostname" != "$hostname" ]]; then
        sudo hostnamectl hostname "$hostname" \
            || return "$(nk::error "$?" 'failed setting hostname')"
        changed='true'
    fi
}

hostname::_provision_unix() {
    declare current_hostname
    current_hostname="$(cat /etc/hostname)"

    if [[ "$current_hostname" != "$hostname" ]]; then
        sudo tee /etc/hostname <<< "$hostname" \
            || return "$(nk::error "$?" 'failed setting hostname')"
        changed='true'
    fi
}

hostname::_provision() {
    if [[ "$OSTYPE" == darwin* ]]; then
        hostname::_provision_macos
    elif which hostnamectl >/dev/null; then
        hostname::hostname::_provision_linux
    else
        hostname::hostname::_provision_unix
    fi
}

hostname::provision() {
    while read -r hostname; do
        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output hostname::_provision; then
            status='failed'
        fi

        declare description="hostname ${hostname}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq -r --compact-output '.[].state')"
}

case "$1" in
    provision)
        hostname::provision "${@:2}"
        ;;
    *)
        echo "hostname: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
