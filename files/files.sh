#!/usr/bin/env bash

set -e

eval "$(nk plugin bash 2>/dev/null)"

files::_perms() {
    if [[ "$OSTYPE" == darwin* ]]; then
        stat -f "%A" "$@"
    else
        stat -c "%a" "$@"
    fi
}

files::_file_identity() {
    if [[ "$OSTYPE" == darwin* ]]; then
        stat -Lf "%d:%i" "$1" 2>/dev/null
    else
        stat -Lc "%d:%i" "$1" 2>/dev/null
    fi
}

files::_provision_file() {
    # TODO: decide how to handle a parent of the destination not existing (ie. esp perms...)
    # - maybe we just add the parent directories to the list of files to create?

    if [[ -d "$source_file" ]]; then
        # create directory
        if [[ ! -d "$destination_file" ]]; then
            # delete existing first
            if [[ -e "$destination_file" ]]; then
                rm -rf "$destination_file"
                changed='true'
            fi

            # create directory
            mkdir "$destination_file"
            changed='true'
        fi

        # chmod directory
        if [[ "$(files::_perms "$destination_file")" != '700' ]]; then
            chmod 0700 "$destination_file"
            changed='true'
        fi
    elif [[ "$link_files" == 'true' ]]; then
        # create link
        if [[ "$(files::_file_identity "$destination_file")" != "$(files::_file_identity "$source_file")" ]]; then
            # delete existing first
            if [[ -d "$destination_file" ]]; then
                rm -rf "$destination_file"
                changed='true'
            fi

            # link file
            ln -sf "${PWD}/${source_file}" "$destination_file"
            changed='true'
        fi
    else
        declare source_contents
        source_contents="$(cat "$source_file")"
        declare destination_contents
        destination_contents="$(cat "$destination_file" 2>/dev/null)"

        # create file
        if [[ "$destination_contents" != "$source_contents" || -L "$destination_file" ]]; then
            # delete existing first
            if [[ -d "$destination_file" || -L "$destination_file" ]]; then
                rm -rf "$destination_file"
                changed='true'
            fi

            # copy file
            cp "$source_file" "$destination_file"
            changed='true'
        fi

        # determine perms to set
        if [[ -x "$source_file" ]]; then
            declare perms='0700'
        else
            declare perms='0600'
        fi

        # chmod file
        if [[ "$(files::_perms "$destination_file")" != "$perms" ]]; then
            chmod "$perms" "$destination_file"
            changed='true'
        fi
    fi
}

files::provision()
{
    while read -r state; do
        declare source_
        source_="$(jq -r '.source' <<< "$state")"
        declare destination
        destination="$(jq -r '.destination' <<< "$state")"
        destination="${destination%/}" # drop optional trailing slash
        declare link_files
        link_files="$(jq -r 'if has("link_files") then .link_files else false end' <<< "$state")"

        # replace tilde
        declare resolved_destination
        resolved_destination="${destination/#~/"$HOME"}"

        # if source does not existing or isn't listable
        if [[ ! -e "$source_" || ( -d "$source_" && ! -x "$source_" ) ]]; then
            declare output=''
            if [[ ! -e "$source_" ]]; then
                output="${source_} does not exist"
            else
                output="${source_} is not listable"
            fi

            nk::log_result \
                'failed' \
                'false' \
                "$destination" \
                "$output"
            continue
        fi

        # iterate all files/directories in source
        while read -r source_file; do
            # figure out destination file path
            declare nested_source_file="${source_file#"${source_}/"}"
            if [[ "$nested_source_file" == "$source_file" ]]; then
                # source file is the source
                declare destination_file="$resolved_destination"
                declare destination_file_tilde="$destination"
            else
                # source file is a child of the source
                declare destination_file="${resolved_destination}/${nested_source_file}"
                declare destination_file_tilde="${destination}/${nested_source_file}"
            fi

            # provision file
            declare status='success'
            declare changed='false'
            declare output=''
            if ! nk::run_for_output output "files::_provision_file"; then
                status='failed'
            fi

            # build description
            if [[ "$link_files" == 'false' || -d "$source_file" ]]; then
                declare action='create'
            else
                declare action='link'
            fi
            declare description="${action} ${destination_file_tilde}"

            # log state details
            nk::log_result \
                "$status" \
                "$changed" \
                "$description" \
                "$output"
        done <<< "$(find "$source_")"
    done <<< "$(jq --compact-output '.[]')"
}

case "$1" in
    provision)
        files::provision "${@:2}"
        ;;
    *)
        echo "files: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
