#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

brew::_provision_package() {
    # tap
    if [[ "$package" == *'/'* ]]; then
        declare tap="${package%'/'*}"
        if ! nk::array::contains "$tap" "${taps[@]}"; then
            brew tap "$tap" || return "$?"
        fi
    fi

    # get info on the package
    declare brew_info
    brew_info="$(brew info --json=v2 "$package")" || return "$?"

    # formula
    declare installed
    declare package_info
    package_info="$(
        jq \
            --arg 'name' "$package" \
            '.formulae[] | select(.name == $name or .full_name == $name or any(.aliases[]; . == $name))' \
            <<<"$brew_info"
    )" || return "$?"

    if [[ -n "$package_info" ]]; then
        installed="$(jq '.installed[]' <<<"$package_info")" || return "$?"
    else
        # cask
        declare cask_name="${package##*/}"
        package_info="$(jq --arg 'name' "$cask_name" '.casks[] | select(.token == $name)' <<<"$brew_info")" || return "$?"
        installed="$(jq -r '.installed // empty' <<<"$package_info")" || return "$?"
    fi

    # ensure package exists
    if [[ -z "$package_info" ]]; then
        echo "could not parse formula/cask info: ${brew_info}"
        return 1
    fi

    if [[ -z "$installed" ]]; then
        # install
        brew install --no-quarantine "$package" || return "$?"
        changed='true'
        action='install'
    elif ! brew outdated --greedy "$package" >/dev/null; then
        # update
        brew upgrade --no-quarantine "$package" || return "$?"
        changed='true'
        action='update'
    fi
}

brew::provision() {
    # collect list of all packages
    declare -a packages=()
    while read -r package; do
        packages+=("$package")
    done <<< "$(jq -r --compact-output '.[]')"

    # list all taps
    declare -a taps=()
    while read -r tap; do
        taps+=("$tap")
    done <<< "$(brew tap -q)"

    # TODO: xcode tools
    # if ! xcode-select -p >/dev/null; then
    #     xcode-select --install
    # fi

    # TODO: brew install
    # if ! which brew >/dev/null; then
    #     # install
    #     NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    #     # update path
    #     eval "$(/opt/homebrew/bin/brew shellenv)"
    # fi

    # update brew (required to know about new versions of packages)
    declare output=''
    if ! nk::run_for_output output brew update --auto-update; then
        # TODO: maybe just always log unchanged?
        # NOTE: only log if it fails
        declare status='failed'
        declare changed='false'
        declare description='brew update'

        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    fi

    # provision packages
    for package in "${packages[@]}"; do
        declare action='install'

        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output brew::_provision_package; then
            status='failed'
        fi

        nk::log_result \
            "$status" \
            "$changed" \
            "${action} package $package" \
            "$output"
    done

    # cleanup
    declare status='success'
    declare output=''
    if ! nk::run_for_output output brew cleanup --prune=1; then
        status='failed'
    fi

    declare changed
    if [[ "$output" == *'This operation has freed approximately'* ]]; then
        changed='false'
    else
        changed='true'
    fi

    declare description="brew cleanup"

    # log state details
    nk::log_result \
        "$status" \
        "$changed" \
        "$description" \
        "$output"
}

case "$1" in
    provision)
        brew::provision "${@:2}"
        ;;
    *)
        echo "brew: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
