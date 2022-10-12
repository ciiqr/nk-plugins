#!/usr/bin/env bash

set -e

eval "$(nk plugin bash 2>/dev/null)"

show::_hex_to_decimal() {
    echo "ibase=16; ${*}" | bc
}

show::_provision_path() {
    declare flags
    flags="$(stat -f '%f' "$resolved_path")"

    # show path
    if (((flags & UF_HIDDEN) != 0)); then
        # show
        chflags nohidden "$resolved_path"

        # update state
        changed='true'
    fi
}

show::provision() {
    # stat flags
    # $ grep UF /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/stat.h
    declare UF_HIDDEN
    UF_HIDDEN="$(show::_hex_to_decimal 8000)"

    while read -r path; do
        # replace tilde
        declare resolved_path
        resolved_path="${path/#~/"$HOME"}"

        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output show::_provision_path; then
            status='failed'
        fi

        declare description="shown ${path}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq -r --compact-output '.[]')"
}

case "$1" in
    provision)
        show::provision "${@:2}"
        ;;
    *)
        echo "show: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
