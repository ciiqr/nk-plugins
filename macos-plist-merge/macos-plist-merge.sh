#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

plist_merge::get_key_path_info() {
    jq -r --compact-output \
        'paths(scalars) as $p | ($p | join(":")), getpath($p), (getpath($p) | type)' \
        || return "$?"
}

plist_merge::has_key_path() {
    /usr/libexec/PlistBuddy -c "Print :${path}" "$plist" 2>/dev/null || return "$?"
}

plist_merge::add_key_path() {
    /usr/libexec/PlistBuddy -c "Add :${path} ${type}" "$plist" || return "$?"
}

plist_merge::_provision_value() {
    declare paths_and_values
    paths_and_values="$(plist_merge::get_key_path_info <<<"$value")" \
        || return "$(nk::error "$?" 'failed peths and values')"

    while read -r path; do
        read -r sub_value
        read -r json_type

        declare existing
        existing="$(/usr/libexec/PlistBuddy -c "Print :${path}" "$plist")" # failures intentionally ignored
        declare normalized # removes unecessary trailing zero and period from floats
        normalized="$(sed -E 's/\.?0+$//' <<<"$existing")" \
            || return "$(nk::error "$?" "failed normalizing value: ${existing}")"

        if [[ "$normalized" != "$sub_value" ]]; then
            # infer type from value type
            declare type=''
            case "$json_type" in
                array)
                    type='array'
                ;;
                object)
                    type='dict'
                ;;
                string)
                    type='string'
                ;;
                boolean)
                    type='bool'
                ;;
                number)
                    # NOTE: if new or existing value have a dot, assume it's a float (the best we can reasonably do)
                    if [[ "$value" == *'.'* || "$existing" == *'.'* ]]; then
                        type='float'
                    else
                        type='int'
                    fi
                ;;
                null)
                    echo "unsupported type: null"
                    return 1
                ;;
            esac

            # add key path
            if ! plist_merge::has_key_path; then
                plist_merge::add_key_path \
                    || return "$(nk::error "$?" "failed adding key path: ${path}")"
                changed='true'
            fi

            # set value
            /usr/libexec/PlistBuddy -c "Set :${path} ${sub_value}" "$plist" \
                || return "$(nk::error "$?" "failed setting value: ${path}: ${sub_value}")"
            changed='true'
        fi

    done <<<"$paths_and_values"
}

plist_merge::provision()
{
    while read -r state; do
        declare plist
        plist="$(jq -r '.plist' <<< "$state")"
        declare value
        value="$(jq -r '.value' <<< "$state")"

        # provision value
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output plist_merge::_provision_value; then
            status='failed'
        fi

        # build description
        declare description="merge values into ${plist}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq --compact-output '.[].state')"
}

case "$1" in
    provision)
        plist_merge::provision "${@:2}"
        ;;
    *)
        echo "plist-merge: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
