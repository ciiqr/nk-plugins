#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

hide::_hex_to_decimal() {
    echo "ibase=16; ${*}" | bc
}

hide::_provision_path() {
    declare flags
    flags="$(stat -f '%f' "$resolved_path")" || return "$?"

    # hide path
    if (((flags & UF_HIDDEN) == 0)); then
        declare -a sudo_if_needed=()
        if [[ "$(stat -f "%u" "$resolved_path")" == '0' ]]; then
            sudo_if_needed+=('sudo')
        fi

        # hide
        "${sudo_if_needed[@]}" chflags hidden "$resolved_path" || return "$?"

        # update state
        changed='true'
    fi
}

hide::provision() {
    # stat flags
    # $ grep UF /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/stat.h
    declare UF_HIDDEN
    UF_HIDDEN="$(hide::_hex_to_decimal 8000)"

    while read -r path; do
        # replace tilde
        declare resolved_path
        resolved_path="${path/#~/$HOME}"

        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output hide::_provision_path; then
            status='failed'
        fi

        declare description="hidden ${path}"

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
        hide::provision "${@:2}"
        ;;
    *)
        echo "hide: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
