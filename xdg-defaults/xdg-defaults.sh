#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2> /dev/null)"

xdg_defaults::_get_app_filename() {
    declare app_name="$1"
    for app_path in "${app_paths[@]}"; do
        if [[ "$app_path" == *"/${app_name}.desktop" ]]; then
            echo "${app_name}.desktop"
            return 0
        fi
    done

    return 1
}

xdg_defaults::_provision_web_browser() {
    # get app filename
    declare app_filename
    app_filename="$(xdg_defaults::_get_app_filename "$program")" \
        || return "$(nk::error "$?" "${program}.desktop not found")"

    # get existing app filename
    declare existing_app_filename
    existing_app_filename="$(xdg-settings get default-web-browser)" # failures intentionally ignored

    # set default
    if [[ "$existing_app_filename" != "$app_filename" ]]; then
        xdg-settings set default-web-browser "$app_filename" || return "$?"
        changed='true'
    fi
}

xdg_defaults::_provision_url_scheme() {
    declare name="${scheme%'://'}"

    # get app filename
    declare app_filename
    app_filename="$(xdg_defaults::_get_app_filename "$program")" \
        || return "$(nk::error "$?" "${program}.desktop not found")"

    # get existing app filename (for protocol)
    declare existing_app_filename
    existing_app_filename="$(xdg-settings get default-url-scheme-handler "$name")" # failures intentionally ignored

    # set default
    if [[ "$existing_app_filename" != "$app_filename" ]]; then
        xdg-settings set default-url-scheme-handler "$name" "$app_filename" || return "$?"
        changed='true'
    fi
}

xdg_defaults::_provision_file_extension() {
    # get app filename
    declare app_filename
    app_filename="$(xdg_defaults::_get_app_filename "$program")" \
        || return "$(nk::error "$?" "${program}.desktop not found")"

    # get existing app filename (for extension)
    declare existing_app_filename
    existing_app_filename="$(xdg-mime query default "$scheme")" # failures intentionally ignored

    # set default
    if [[ "$existing_app_filename" != "$app_filename" ]]; then
        xdg-mime default "$app_filename" "$scheme" || return "$?"
        changed='true'
    fi
}

xdg_defaults::_provision_default() {
    if [[ "$scheme" == 'web-browser' ]]; then
        xdg_defaults::_provision_web_browser || return "$?"
    elif [[ "$scheme" == *'://' ]]; then
        xdg_defaults::_provision_url_scheme || return "$?"
    elif [[ "$scheme" == *'/'* ]]; then
        xdg_defaults::_provision_file_extension || return "$?"
    else
        echo "unrecognized format '${scheme}' must be a url scheme (ie. 'https://'), file extension (ie. 'text/html'), or 'web-browser'"
        return 1
    fi
}

xdg_defaults::provision() {
    # find all app directories
    declare -a app_directories=(
        # user applications directory
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    )

    if [[ -n "$XDG_DATA_DIRS" ]]; then
        # system application directories
        declare xdg_data_dirs
        IFS=':' read -ra xdg_data_dirs <<< "$XDG_DATA_DIRS"

        declare dir
        for dir in "${xdg_data_dirs[@]}"; do
            app_directories+=("${dir}/applications")
        done
    else
        # default system application directories
        app_directories+=(
            "/usr/local/share/applications"
            "/usr/share/applications"
        )
    fi

    # list all app paths
    declare -a app_paths=()
    while read -r app_path; do
        app_paths+=("$app_path")
    done <<< "$(find "${app_directories[@]}" -mindepth 1 -maxdepth 1 -name '*.desktop' 2> /dev/null)"

    while read -r state; do
        while read -r scheme; do
            declare program
            program="$(jq -r --arg 'scheme' "$scheme" '.[$scheme]' <<< "$state")"

            # provision
            declare status='success'
            declare changed='false'
            declare output=''
            if ! nk::run_for_output output xdg_defaults::_provision_default; then
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
    done <<< "$(jq -r --compact-output '.[].state')"
}

case "$1" in
    provision)
        xdg_defaults::provision "${@:2}"
        ;;
    *)
        echo "xdg-defaults: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
