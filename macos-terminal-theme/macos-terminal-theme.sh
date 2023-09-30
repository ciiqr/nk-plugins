#!/usr/bin/env bash

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

terminal_theme::get_default_theme() {
    osascript <<<'tell application "Terminal" to return name of default settings' || return "$?"
}

terminal_theme::set_default_theme() {
    osascript - "$@" <<<'
        on run argv
            tell application "Terminal"
                set themeName to item 1 of argv
                set themeFile to item 2 of argv

                -- store ids of open windows
                set initiallyOpenWindows to id of every window

                -- open theme in new window (so it gets added to the available themes)
                do shell script "open -a Terminal " & quoted form of themeFile

                -- wait for the new window to open and finish loading, then close it
                repeat
                    set closed to false
                    set allOpenWindows to id of every window

                    repeat with windowId in allOpenWindows
                        try
                            if initiallyOpenWindows does not contain windowId then
                                set newWindow to (first window whose id is windowId)
                                set newTab to (first tab of newWindow)

                                if not busy of newTab then
                                    set closed to true
                                    close newWindow
                                end if
                            end if
                        on error errMsg
                            log "ERROR: " & errMsg
                        end try
                    end repeat

                    if closed then
                        exit repeat
                    end if

                    delay 0.02
                end repeat

                -- set the custom theme as the default theme
                set default settings to settings set themeName

                -- apply theme to open tabs immediately
                repeat with windowId in initiallyOpenWindows
                    try
                        set current settings of tabs of (every window whose id is windowId) to settings set themeName
                    on error errMsg
                        -- NOTE: only for debugging because Terminal always has a
                        -- dummy/background window that breaks everything
                        -- log "ERROR: " & errMsg
                    end try
                end repeat
            end tell
        end run
    ' || return "$?"
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
