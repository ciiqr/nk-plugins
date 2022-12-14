#!/usr/bin/env bash

set -e

while read -r plugin_yml; do
    declare name
    name="$(yq '.name' "$plugin_yml")"
    declare executable
    executable="$(yq '.executable' "$plugin_yml")"
    declare when
    when="$(yq '.when' "$plugin_yml")"
    declare plugin_dir
    plugin_dir="$(dirname "$plugin_yml")"

    # TODO: make this smarter (maybe just have a release.yml config in in plugin dir)
    # determine asset file name
    declare asset_file
    if [[ "$when" == 'family == "unix"' ]]; then
        asset_file="${name}-unix.tar.gz"
    elif [[ "$when" == 'os == "macos"' ]]; then
        asset_file="${name}-macos.tar.gz"
    else
        echo "could not determine asset name for ${name}: ${when}"
        exit 1
    fi

    # absolute asset path
    declare asset_path
    asset_path="${PWD}/${asset_file}"

    # plugin files relative to plugin dir
    declare -a plugin_files=(
        "${plugin_yml/#$plugin_dir/.}"
        "$executable"
    )

    # create asset file
    tar czf "$asset_path" \
        --directory "$plugin_dir" \
        "${plugin_files[@]}"
done <<< "$(find . -mindepth 2 -maxdepth 2 -name 'plugin.yml')"
