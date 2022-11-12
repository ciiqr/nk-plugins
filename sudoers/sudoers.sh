#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

sudoers::_provision_file() {
    declare file="$1"
    declare config="$2"

    # check config
    visudo --check --strict --file=- <<<"$config" \
        || return "$(nk::error "$?" "config invalid: ${config}")"

    # get existing contents
    declare existing_contents
    existing_contents="$(sudo cat "$file" 2>/dev/null)" # failures intentionally ignored

    # create config
    if [[ "$existing_contents" != "$config" ]]; then
        sudo tee "$file" >/dev/null <<<"$config" || return "$?"
        changed='true'
    fi
}

sudoers::_provision_mode() {
    if [[ "$mode" == 'passwordless' ]]; then
        declare user_config="${USER} ALL=(ALL:ALL) NOPASSWD:ALL"
    else
        declare user_config="${USER} ALL=(ALL:ALL) ALL"
    fi

    # create user config
    sudoers::_provision_file "/etc/sudoers.d/user-${USER}" "$user_config" || return "$?"

    # TODO: configure touch id
    # /etc/pam.d/sudo
    # auth sufficient pam_tid.so
}

sudoers::_provision_defaults() {
    # create defaults config
    sudoers::_provision_file "/etc/sudoers.d/defaults" "$defaults" || return "$?"
}

sudoers::_sudo_or_promote_to_root() {
    # try to use sudo
    if sudo -n true; then
        # either passwordless sudo or user has recently run sudo and it hasn't timed out yet
        return 0
    fi

    # TODO: need to setup parsing of cli args, then we can enable the below hack (macos only obvs)
    # TODO: alternatively, figure out something in nk directly to promote (maybe just running `sudo true` before provisioning so the user can actually input something)
    return 1

    #     # if not run as root, prompt user to allow this to run as root
    #     # NOTE: Must use `whoami`, $USER won't be set when run this way, which will cause this to trigger recursively
    #     if [[ "$(whoami)" != 'root' ]]; then
    #         exec osascript - "$0" "$@" 3<&0 <<APPLESCRIPT
    #         on run argv
    #             set stdin to do shell script "cat 0<&3"
    #             set command to ""
    #             repeat with arg in argv
    #                 set command to command & quoted form of arg & " "
    #             end repeat

    #             do shell script (command & " <<< " & quoted form of stdin) with administrator privileges
    #         end run
    # APPLESCRIPT
    #     fi
}

sudoers::provision() {
    sudoers::_sudo_or_promote_to_root provision "$@"

    while read -r state; do
        # TODO: consider a better interface...
        declare mode
        mode="$(jq -r '.mode' <<< "$state")"
        declare defaults
        defaults="$(jq -r '.defaults' <<< "$state")"

        # configure mode
        if [[ -n "$mode" ]]; then
            declare status='success'
            declare changed='false'
            declare output=''
            if ! nk::run_for_output output sudoers::_provision_mode; then
                status='failed'
            fi

            declare description="sudoers ${mode} ${USER}"

            # log state details
            nk::log_result \
                "$status" \
                "$changed" \
                "$description" \
                "$output"
        fi

        # configure defaults
        if [[ -n "$defaults" ]]; then
            declare status='success'
            declare changed='false'
            declare output=''
            if ! nk::run_for_output output sudoers::_provision_defaults; then
                status='failed'
            fi

            declare description="sudoers defaults"

            # log state details
            nk::log_result \
                "$status" \
                "$changed" \
                "$description" \
                "$output"
        fi
    done <<< "$(jq -r --compact-output '.[]')"
}

case "$1" in
    provision)
        sudoers::provision "${@:2}"
        ;;
    *)
        echo "sudoers: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
