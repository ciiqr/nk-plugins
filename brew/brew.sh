#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

brew::_provision_package() {
    # formula
    declare outdated
    declare installed_version
    declare latest_version
    declare package_info
    package_info="$(
        jq \
            --arg 'name' "$package" \
            '.formulae[] | select(.name == $name or .full_name == $name or any(.aliases[]; . == $name))' \
            <<<"$brew_info"
    )" || return "$?"

    if [[ -n "$package_info" ]]; then
        installed_version="$(jq -r '.installed[0].version // empty' <<<"$package_info")" || return "$?"
        latest_version="$(jq -r '.versions.stable // empty' <<<"$package_info")" || return "$?"
        outdated="$(jq '.outdated' <<<"$package_info")" || return "$?"
    else
        # cask
        declare cask_name="${package##*/}"
        package_info="$(jq --arg 'name' "$cask_name" '.casks[] | select(.token == $name)' <<<"$brew_info")" || return "$?"
        installed_version="$(jq -r '.installed // empty' <<<"$package_info")" || return "$?"
        latest_version="$(jq -r '.version // empty' <<<"$package_info")" || return "$?"
        outdated="$(jq -r '.outdated // empty' <<<"$package_info")" || return "$?"
    fi

    # remove _\d$ from $installed_version (it's not there in the latest version, but the versions will otherwise match)
    installed_version="${installed_version%_[0-9]}"

    # ensure package exists
    if [[ -z "$package_info" ]]; then
        echo 'could not find package'
        return 1
    fi

    if [[ -z "$installed_version" ]]; then
        # install
        brew install --no-quarantine "$package" || return "$?"
        changed='true'
        action='install'
    elif [[ "$outdated" == 'true' ]] ||
        [[ -n "$installed_version" && -n "$latest_version"
            && "$installed_version" != "$latest_version" ]]; then
        # NOTE: version check because auto_update packages aren't shown as outdated (even that )

        # update
        brew upgrade --no-quarantine "$package" || return "$?"
        changed='true'
        action='update'
    fi
}

brew::_provision_brew_cli() {
    if ! which brew >/dev/null; then
        # install
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            || return "$(nk::error "$?" 'failed installing brew cli')"
        changed='true'

        # determine brew prefix
        declare brew_prefix
        if [[ "$(uname -m)" == 'arm64' ]]; then
            brew_prefix=/opt/homebrew
        else
            brew_prefix=/usr/local
        fi

        # update path (for this script only)
        eval "$("${brew_prefix}/bin/brew" shellenv)" \
            || return "$(nk::error "$?" 'failed update path with brew')"
    fi
}

brew::provision() {
    # collect list of all packages
    declare -a packages=()
    while read -r package; do
        packages+=("$package")
    done <<< "$(jq -r --compact-output '.[].state')"

    # install brew
    declare status='success'
    declare changed='false'
    declare output=''
    if ! nk::run_for_output output brew::_provision_brew_cli; then
        status='failed'
    fi
    nk::log_result \
        "$status" \
        "$changed" \
        'installed brew' \
        "$output"

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

    # list all taps
    declare -a taps=(
        # NOTE: should no longer be tapped
        'homebrew/core'
        'homebrew/cask'
    )
    while read -r tap; do
        taps+=("$tap")
    done <<< "$(brew tap -q)"

    # tap all untapped taps
    for package in "${packages[@]}"; do
        if [[ "$package" == *'/'* ]]; then
            declare tap="${package%'/'*}"
            if ! nk::array::contains "$tap" "${taps[@]}"; then
                declare output=''
                # TODO: fix this prompting for credentials when tap doesn't exist...
                # - GIT_TERMINAL_PROMPT=0 should prevent it, but doesn't for some reason...
                if ! nk::run_for_output output brew tap "$tap"; then
                    nk::log_result \
                        'failed' \
                        'false' \
                        "brew tap \"${tap}\"" \
                        "$output"
                fi

                # append to list of taps
                taps+=("$tap")
            fi
        fi
    done

    # get info on all packages
    declare -a brew_info_packages=("${packages[@]}")
    declare brew_info
    while [[ -z "$brew_info" || "$brew_info" == 'Error: No available formula'* ]]; do
        declare exit_code='0'
        # TODO: fix proper
        brew_info="$(brew info --json=v2 "${brew_info_packages[@]}" 2>/dev/null)" || exit_code="$?"

        if [[ "$exit_code" == '0' ]]; then
            break
        fi

        if [[ "$brew_info" == 'Error: No available formula'* ]]; then
            # extract package name from error
            declare invalid_package
            invalid_package="$(sed -nE 's/Error: No available formula( or cask)? with the name "(.*)"\..*/\2/p' <<< "$brew_info")"

            # remove invalid package so we can retry
            for i in "${!brew_info_packages[@]}"; do
                if [[ "${brew_info_packages[i]}" == "$invalid_package" ]]; then
                    unset 'brew_info_packages[i]'
                fi
            done
        else
            # failed fetching package info...
            nk::log_result \
                'failed' \
                'false' \
                'fetching brew package info' \
                "$brew_info"

            # exit early since we can't do much more without package info
            return "$exit_code"
        fi
    done

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
        changed='true'
    else
        changed='false'
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
