#!/usr/bin/env bash

set -e

eval "$(nk plugin bash 2>/dev/null)"

# TODO: might need to `brew tap` for some packages ie. `brew tap homebrew/cask`
brew::_provision_package() {
    # get info on the package
    declare brew_info
    brew_info="$(brew info --json=v2 "$package")"

    # formula
    declare installed
    declare package_info
    package_info="$(jq --arg 'name' "$package" '.formulae[] | select(.name == $name or .full_name == $name or any(.aliases[]; . == $name))' <<<"$brew_info")"
    if [[ -n "$package_info" ]]; then
        installed="$(jq '.installed[]' <<<"$package_info")"
    else
        # cask
        declare cask_name="${package##*/}"
        package_info="$(jq --arg 'name' "$cask_name" '.casks[] | select(.token == $name)' <<<"$brew_info")"
        installed="$(jq '.installed' <<<"$package_info")"
    fi

    # ensure package exists
    if [[ -z "$package_info" ]]; then
        echo "could not parse formula/cask info: ${brew_info}"
        return 1
    fi

    if [[ -z "$installed" ]]; then
        # install
        brew install "$package"
        changed='true'
        action='install'
    elif ! brew outdated --greedy "$package" >/dev/null; then
        # upgrade
        brew upgrade "$package"
        changed='true'
        action='upgrade'
    fi
}

brew::provision() {
    # collect list of all packages
    declare -a packages=()
    while read -r package; do
        packages+=("$package")
    done <<< "$(jq -r --compact-output '.[]')"

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
