#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

pmset::_get_values() {
    declare current_source=''
    while read -r line; do
        case "$line" in
            'Battery Power:')
                current_source='battery'
            ;;
            'AC Power:')
                current_source='ac'
            ;;
            'Sleep On')
                : # discard
            ;;
            *)
                declare current_name
                current_name="$(cut -d' ' -f1 <<< "$line")"
                declare current_value
                current_value="$(cut -d' ' -f2 <<< "$line")"

                # add to per-source lists
                if [[ "$current_source" == 'battery' ]]; then
                    existing_battery_values+=(["$current_name"]="$current_value")
                elif [[ "$current_source" == 'ac' ]]; then
                    existing_ac_values+=(["$current_name"]="$current_value")
                else
                    echo 'could not parse existing pmset settings'
                    return 1
                fi

                if [[ -z "${existing_all_values["$current_name"]}" ]]; then
                    # add to 'all' list
                    existing_all_values+=(["$current_name"]="$current_value")
                elif [[ "${existing_all_values["$current_name"]}" != "$current_value" ]]; then
                    # it's already set and the sources have different values. clear it so that if it's set in the 'all' state, it'll trigger a change
                    existing_all_values+=(["$current_name"]="")
                fi
            ;;
        esac
    done <<< "$(pmset -g custom | awk '{ print $1, $2 }')"
}

pmset::_provision_value() {
    # get existing value
    declare existing_value=''
    if [[ "$source_" == 'all' ]]; then
        existing_value="${existing_all_values["$name"]}"
    elif [[ "$source_" == 'ac' ]]; then
        existing_value="${existing_ac_values["$name"]}"
    elif [[ "$source_" == 'battery' ]]; then
        existing_value="${existing_battery_values["$name"]}"
    fi

    # set value
    if [[ "$existing_value" != "$value" ]]; then
        declare source_flag=''
        if [[ "$source_" == 'all' ]]; then
            source_flag='-a'
        elif [[ "$source_" == 'ac' ]]; then
            source_flag='-c'
        elif [[ "$source_" == 'battery' ]]; then
            source_flag='-b'
        fi

        # set
        sudo pmset "$source_flag" "$name" "$value" || return "$?"
        changed='true'
    fi
}

pmset::provision() {
    # read existing values
    declare -A existing_all_values=()
    declare -A existing_ac_values=()
    declare -A existing_battery_values=()
    pmset::_get_values

    while read -r state; do
        while read -r source_; do
            while read -r name; do
                declare value
                value="$(
                    jq \
                        -r \
                        --arg 'source' "$source_" \
                        --arg 'name' "$name" \
                        '.[$source] | .[$name]' \
                        <<< "$state"
                )"

                # provision
                declare status='success'
                declare changed='false'
                declare output=''
                if ! nk::run_for_output output pmset::_provision_value; then
                    status='failed'
                fi

                declare description="pmset ${source_} ${name}"

                # log state details
                nk::log_result \
                    "$status" \
                    "$changed" \
                    "$description" \
                    "$output"
            done <<< "$(jq -r --arg 'source' "$source_" '.[$source] | keys[]' <<< "$state")"
        done <<< "$(jq -r 'keys[]' <<< "$state")"
    done <<< "$(jq -r --compact-output '.[].state')"
}

case "$1" in
    provision)
        pmset::provision "${@:2}"
        ;;
    *)
        echo "pmset: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
