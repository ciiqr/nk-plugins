#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin bash 2>/dev/null)"

terminal_theme::get_default_theme() {
    # TODO: instead of first window, try using current window (I believe the background window might be causing issues with this rn)
    osascript <<<'tell application "Terminal" to return name of current settings of first window' || return "$?"
}

terminal_theme::set_default_theme() {
    osascript - "$@" <<'EOF' || return "$?"
        on run argv
            tell application "Terminal"
                local allOpenWindows
                local initiallyOpenWindows
                local windowId
                local name
                set themeName to item 1 of argv
                set themeFile to item 2 of argv

                (* Store the IDs of all the open terminal windows. *)
                set initiallyOpenWindows to id of every window

                (* Open the custom theme so that it gets added to the list of available terminal themes. This will temporarily open additional windows. *)
                do shell script "open -a Terminal " & quoted form of themeFile

                (* Wait a little bit to ensure that the custom theme is added. *)
                delay 10

                (* Set the custom theme as the default terminal theme. *)
                set default settings to settings set themeName

                (* Get the IDs of all the currently opened terminal windows. *)
                set allOpenWindows to id of every window

                repeat with windowId in allOpenWindows
                    if initiallyOpenWindows does not contain windowId then
                        (* Close the additional windows that were opened in order to add the custom theme to the list of terminal themes. *)
                        close (every window whose id is windowId)
                    else
                        set name to name of (every window whose id is windowId)
                        -- NOTE: there seems to be an extra window open (in the background or something)
                        -- Trying to change its settings throws an error so we skip it (luckily it doesn't have a name, so we skip based on that)
                        if (name as string) is not equal to "" then
                            (* Change the theme for the initial opened terminal windows to remove the need to close them in order for the custom theme to be applied. *)
                            set current settings of tabs of (every window whose id is windowId) to settings set themeName
                        end if
                    end if
                end repeat
            end tell
        end run
EOF
}

terminal_theme::_provision_theme() {
    # resolve theme path relative to the source directories
    declare resolved_theme_path=""
    for nk_source in "${nk_sources[@]}"; do
        declare source_theme_path="${nk_source}/${theme_path}"
        if [[ -f "$source_theme_path" ]]; then
            resolved_theme_path="$source_theme_path"
        fi
    done

    declare theme_name
    theme_name="$(/usr/libexec/PlistBuddy -c "Print :name" "$resolved_theme_path")" || return "$?"

    declare current_theme
    current_theme="$(terminal_theme::get_default_theme)" || return "$?"

    if [[ "$current_theme" != "$theme_name" ]]; then
        # change theme
        terminal_theme::set_default_theme "$theme_name" "$resolved_theme_path" || return "$?"
        changed='true'
    fi
}

terminal_theme::provision() {
    if [[ "$CI" == 'true' ]]; then
        # TODO: would be nice to make this work but it's a real pain working around the gui prompt we're getting: "bash" wants access to control "Terminal"
        return 0
    fi

    declare info="$1"
    declare -a nk_sources=()
    while read -r nk_source; do
        nk_sources+=("$nk_source")
    done <<< "$(jq -r --compact-output '.sources[]' <<<"$info")"

    while read -r theme_path; do
        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output terminal_theme::_provision_theme; then
            status='failed'
        fi

        declare description="terminal theme ${theme_path}"

        # log state details
        nk::log_result \
            "$status" \
            "$changed" \
            "$description" \
            "$output"
    done <<< "$(jq -r --compact-output '.[].state')"
}

case "$1" in
    provision)
        terminal_theme::provision "${@:2}"
        ;;
    *)
        echo "terminal-theme: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
