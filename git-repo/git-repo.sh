#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

git_repo::_provision_repo() {
    declare destination_repo_url
    destination_repo_url="$(git -C "$resolved_destination" remote get-url origin 2>/dev/null)" # failures intentionally ignored

    # if remote name doesn't match
    if [[ "$destination_repo_url" != "$source_" ]]; then
        # clone
        git clone "$source_" "$resolved_destination" \
            || return "$(nk::error "$?" "failed cloning ${source_} into ${resolved_destination}")"
        changed='true'
    elif [[ "$should_update" == 'true' ]]; then
        # update
        git -C "$resolved_destination" fetch \
            || return "$(nk::error "$?" 'failed fetching latest changes')"

        declare local_ref
        local_ref="$(git -C "$resolved_destination" rev-parse @)" \
            || return "$(nk::error "$?" 'failed getting current ref')"

        declare remote_ref
        remote_ref="$(git -C "$resolved_destination" rev-parse '@{u}')" \
            || return "$(nk::error "$?" 'failed getting remote ref')"

        if [[ "$local_ref" != "$remote_ref" ]]; then
            git -C "$resolved_destination" pull \
                || return "$(nk::error "$?" 'failed pulling latest changes')"
            changed='true'
        fi
    fi
}

git_repo::provision()
{
    while read -r state; do
        declare source_
        source_="$(jq -r '.source' <<< "$state")"
        declare destination
        destination="$(jq -r '.destination' <<< "$state")"
        destination="${destination%/}" # drop optional trailing slash
        declare should_update
        should_update="$(jq -r 'if has("update") then .update else true end' <<< "$state")"

        # replace tilde
        declare resolved_destination
        resolved_destination="${destination/#~/$HOME}"

        # provision repo
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output git_repo::_provision_repo; then
            status='failed'
        fi

        # build description
        declare description="clone ${source_} into ${destination}"

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
        git_repo::provision "${@:2}"
        ;;
    *)
        echo "git-repo: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
