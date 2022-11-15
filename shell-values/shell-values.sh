#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

shell_values::build_file() {
    declare definition_prefix='declare'
    if [[ "$should_export" == 'true' ]]; then
        definition_prefix='export'
    fi

    declare contents=""
    while read -r key; do
        read -e value || return "$?"

        # TODO: need to escape values properly incase a var includes a single quote
        contents+="${definition_prefix} ${key}='${value}'"$'\n'
    done <<< "$(jq -r --compact-output 'to_entries[] | .key, .value' <<<"$values")"

    echo "$contents"
}

shell_values::_provision_values() {
    declare contents
    contents="$(shell_values::build_file)" || return "$?"
    declare destination_contents
    destination_contents="$(cat "$resolved_destination" 2>/dev/null)" # failures intentionally ignored

    # create parent directory
    declare destination_parent
    destination_parent="$(dirname "$resolved_destination")"
    if [[ ! -d "$destination_parent" ]]; then
        mkdir -p "$destination_parent" \
            || return "$(nk::error "$?" "failed creating parent directory: ${destination_parent}")"
        changed='true'
    fi

    # create file
    if [[ "$destination_contents" != "$contents" ]]; then
        cat <<<"$contents" >"$resolved_destination" \
            || return "$(nk::error "$?" "failed writting file: ${resolved_destination}")"
        changed='true'
    fi
}

shell_values::provision()
{
    while read -r state; do
        declare values
        values="$(jq -r '.values' <<< "$state")"
        declare destination
        destination="$(jq -r '.destination' <<< "$state")"
        declare should_export
        should_export="$(jq -r 'if has("export") then .export else false end' <<< "$state")"

        # replace tilde
        declare resolved_destination
        resolved_destination="${destination/#~/$HOME}"

        # provision repo
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output shell_values::_provision_values; then
            status='failed'
        fi

        # build description
        declare description="shell values ${destination}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq --compact-output '.[]')"
}

case "$1" in
    provision)
        shell_values::provision "${@:2}"
        ;;
    *)
        echo "shell-values: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
