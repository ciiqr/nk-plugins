#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

default_programs::_get_app_id() {
    osascript - "$@" <<'EOF'
        on run argv
            return id of app (item 1 of argv)
        end run
EOF
}

default_programs::_provision_url_schema() {
    declare name="${scheme%'://'}"

    # get bundle id
    declare bundle_id
    bundle_id="$(default_programs::_get_app_id "$program")" || return "$?"

    # get existing bundle id (for extension)
    declare existing_bundle_id
    existing_bundle_id="$(duti -d "$name")" # failures intentionally ignored

    # set default
    if [[ "$existing_bundle_id" != "$bundle_id" ]]; then
        duti -s "$bundle_id" "$name" all || return "$?"
        changed='true'
    fi
}

default_programs::_provision_file_extension() {
    declare name="${scheme#'.'}"

    # get bundle id
    declare bundle_id
    bundle_id="$(default_programs::_get_app_id "$program")" || return "$?"

    # get existing bundle id (for extension)
    declare existing_bundle_id
    existing_bundle_id="$(duti -x "$name" | tail -1)" # failures intentionally ignored

    # set default
    if [[ "$existing_bundle_id" != "$bundle_id" ]]; then
        duti -s "$bundle_id" "$scheme" all || return "$?"
        changed='true'
    fi
}

default_programs::_provision_default() {
    if [[ "$scheme" == *'://' ]]; then
        default_programs::_provision_url_schema || return "$?"
    elif [[ "$scheme" == '.'* ]]; then
        default_programs::_provision_file_extension || return "$?"
    else
        echo "unrecognized format '${scheme}' must be url schems (ie. 'https://') or file extension (ie. '.md')"
        return 1
    fi
}

default_programs::provision() {
    while read -r state; do
        while read -r scheme; do
            declare program
            program="$(jq -r --arg 'scheme' "$scheme" '.[$scheme]' <<< "$state")"

            # provision
            declare status='success'
            declare changed='false'
            declare output=''
            if ! nk::run_for_output output default_programs::_provision_default; then
                status='failed'
            fi

            declare description="default-program ${scheme}"

            # log state details
            nk::log_result \
                "$status" \
                "$changed" \
                "$description" \
                "$output"
        done <<< "$(jq -r 'keys[]' <<< "$state")"
    done <<< "$(jq -r --compact-output '.[]')"
}

case "$1" in
    provision)
        default_programs::provision "${@:2}"
        ;;
    *)
        echo "default-programs: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
