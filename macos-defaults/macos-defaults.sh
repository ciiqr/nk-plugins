#!/usr/bin/env bash

set -e

eval "$(nk plugin bash 2>/dev/null)"

default::_domain_file() {
    if [[ "$domain" == 'NSGlobalDomain' ]]; then
        echo "${HOME}/Library/Preferences/.GlobalPreferences.plist"
        return 0
    fi

    declare domain_name="${domain%.plist}"
    declare -a possible_plists=(
        # path to config
        # NOTE: we still strip the .plist off first because it's valid to provide the path without the extension to `defaults`
        "${domain_name}.plist"
        # user configs
        "${HOME}/Library/Preferences/${domain_name}.plist"
        # root configs
        "/Library/Preferences/${domain_name}.plist"
        # sandboxed app configs ie. com.apple.TextEdit
        "${HOME}/Library/Containers/${domain_name}/Data/Library/Preferences/${domain_name}.plist"
    )

    for plist in "${possible_plists[@]}"; do
        if [[ -f "$plist" ]]; then
            echo "$plist"
            return 0
        fi
    done

    return 1
}

defaults::_provision_default() {
    # get type
    if [[ -z "$type" ]]; then
        # read existing type
        case "$(defaults read-type "$domain" "$name" 2>/dev/null)" in
            'Type is array')
                type='array'
            ;;
            'Type is dictionary')
                type='dict'
            ;;
            # TODO: treat date as string?
            'Type is string')
                type='string'
            ;;
            'Type is boolean')
                type='bool'
            ;;
            'Type is float')
                type='float'
            ;;
            'Type is integer')
                type='int'
            ;;
            *)
                # infer type from value type
                declare json_type
                json_type="$(jq -r '.value | type' <<< "$state")"
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
                        if [[ "$value" == *'.'* ]]; then
                            type='float'
                        else
                            # NOTE: likely still to be wrong in many cases, user will have to specify 'float'
                            type='int'
                        fi
                    ;;
                    null)
                        echo "unsupported type: null"
                        return 1
                    ;;
                esac
            ;;
        esac
    fi

    # get domain plist file
    declare domain_file
    domain_file="$(default::_domain_file)"

    # comparable value
    declare comparable_value="$value"

    # previous value
    declare previous_value
    previous_value="$(defaults read "$domain" "$name" 2>/dev/null || true)"

    # parse
    case "$type" in
        array|dict)
            # TODO: this doesn't work for all plists (some are not convertable to json...). Would potentially be more flexible/useful though...
            # TODO: I've seen some examples "transforming" the plist to be compatible, none have worked for me tho: ie. cat ... | sed -Ee 's#<(\/)?dat[ae]>#<\1string>#g' | plutil -convert json -r -o - -- -
            # NOTE: compact & sorted keys to simplify comparing to value
            # previous_value="$(plutil -extract "$name" json -o - "$domain_file" | jq --compact-output --sort-keys -r '.')"

            # format previous value
            previous_value="$(/usr/libexec/PlistBuddy -c "Print :${name}" "$domain_file" 2>/dev/null || true)"

            # format new value
            plutil -convert xml1 -r -o - -- - <<< "$value" > "$temp_value_format_file"
            comparable_value="$(/usr/libexec/PlistBuddy -c "Print" "$temp_value_format_file")"

            # NOTE: this is pretty dumb, but the order of keys is different, so
            # we need to sort these to be able to compare (is fine as long as we
            # only need to compare these values and nothing else...)
            if [[ "$type" == 'dict' ]]; then
                previous_value="$(sort <<< "$previous_value")"
                comparable_value="$(sort <<< "$comparable_value")"
            fi
        ;;
        bool)
            case "$previous_value" in
                0)
                    previous_value='false'
                ;;
                1)
                    previous_value='true'
                ;;
            esac
        ;;
    esac

    # TODO: consider making plist backups somewhere... (only if backup doesn't exist, just so we preserve the originals)
    # ie. defaults export "$backup_plist"

    # write default
    if [[ "$previous_value" != "$comparable_value" ]]; then
        if [[ "$type" == 'dict' ]]; then
            # TODO: evaluate what this would look like with `defaults write`, I suspect this is just strictly easier...
            plutil -replace "$name" -json "$value" "$domain_file"
        else
            declare value_args=()
            if [[ "$type" == 'array' ]]; then
                # TODO: check if the plutil flow above "just" works for arrays?
                while read -r value_element; do
                    value_args+=("$value_element")
                done <<< "$(jq -r --compact-output '.[]' <<< "$value")"
            else
                value_args+=("$value")
            fi

            defaults write \
                "$domain" \
                "$name" \
                "-${type}" \
                "${value_args[@]}"
        fi

        changed='true'
    fi
}

defaults::provision() {
    declare -a programs_to_reset=()

    temp_value_format_file="$(mktemp)"
    on_exit() {
        rm "$temp_value_format_file"
    }
    trap on_exit EXIT

    while read -r state; do
        declare domain
        domain="$(jq -r '.domain' <<< "$state")"
        declare name
        name="$(jq -r '.name' <<< "$state")"
        declare value
        value="$(jq -r '.value' <<< "$state")"
        # # TODO: only compact/sort if we actually end up comparing json...
        # # NOTE: compact & sorted keys to simplify comparing to existing value
        # value="$(jq --compact-output --sort-keys -r '.value' <<< "$state")"

        # declare root # TODO: implied if plist is owned by root? (may also want to check if writable...)
        # # x NSGlobalDomain = ~/Library/Preferences/.GlobalPreferences.plist
        # # - ~/Library/Preferences/{domain}.plist
        # # - /Library/Preferences/{domain}.plist
        # # x com.apple.TextEdit.plist = ~/Library/Containers/com.apple.TextEdit/Data/Library/Preferences/com.apple.TextEdit.plist
        # root="$(jq -r 'if has("root") then .root else "" end' <<< "$state")"

        declare resets # ie. Finder / Dock / etc
        resets="$(jq -r 'if has("resets") then .resets else "" end' <<< "$state")"
        declare type=''
        # TODO: unsure if we'll need
        # type="$(jq -r 'if has("type") then .type else "" end' <<< "$state")"

        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output defaults::_provision_default; then
            status='failed'
        fi

        # append to resets set
        if [[ -n "$resets" && "$changed" == 'true' && "$status" == 'success' ]]; then
            if ! nk::array::contains "$resets" "${programs_to_reset[@]}"; then
                programs_to_reset+=("$resets")
            fi
        fi

        declare description="default ${domain} ${name}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq -r --compact-output '.[]')"

    # reset required programs
    for program in "${programs_to_reset[@]}"; do
        declare status='success'
        declare changed='true' # NOTE: defaults to true unless it fails, could be wrong either way though
        declare output=''
        if ! nk::run_for_output output killall "$program"; then
            status='failed'
            changed='false'
        fi

        declare description="reset ${program}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done
}

case "$1" in
    provision)
        defaults::provision "${@:2}"
        ;;
    *)
        echo "defaults: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
