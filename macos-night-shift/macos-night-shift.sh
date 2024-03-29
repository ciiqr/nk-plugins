#!/usr/bin/env bash

# TODO: consider dropping and supporting through macos.defaults (once we have vars & var plugins)

# NOTE: DOES NOT APPLY TO FUNCTIONS CALLED INSIDE IF CONDITIONS OR WITH ||/&& CHAINS
set -e

eval "$(nk plugin helper bash 2>/dev/null)"

night_shift::_provision_default() {
    declare generated_uid
    generated_uid="$(dscl . -read ~/ 'GeneratedUID' | cut -d' ' -f2)" || return "$?"

    declare name="CBUser-${generated_uid}"

    # TODO: handle parts not being set? or just have schema require all...
    declare schedule_day_hour
    schedule_day_hour="$(jq '.day.hour' <<< "$schedule")" || return "$?"
    declare schedule_day_minute
    schedule_day_minute="$(jq '.day.minute' <<< "$schedule")" || return "$?"
    declare schedule_night_hour
    schedule_night_hour="$(jq '.night.hour' <<< "$schedule")" || return "$?"
    declare schedule_night_minute
    schedule_night_minute="$(jq '.night.minute' <<< "$schedule")" || return "$?"

    declare value
    value="$(
        jq \
        --null-input \
        --compact-output \
        --argjson 'schedule_day_hour' "$schedule_day_hour" \
        --argjson 'schedule_day_minute' "$schedule_day_minute" \
        --argjson 'schedule_night_hour' "$schedule_night_hour" \
        --argjson 'schedule_night_minute' "$schedule_night_minute" \
        '{
            "CBBlueReductionStatus": {
                "AutoBlueReductionEnabled": 1,
                "BlueLightReductionDisableScheduleAlertCounter": 3,
                "BlueLightReductionSchedule": {
                    "DayStartHour": $schedule_day_hour,
                    "DayStartMinute": $schedule_day_minute,
                    "NightStartHour": $schedule_night_hour,
                    "NightStartMinute": $schedule_night_minute
                },
                "BlueReductionAvailable": true,
                "BlueReductionEnabled": 0,
                "BlueReductionMode": 2,
                "BlueReductionSunScheduleAllowed": true,
                "Version": 1
            }
        }'
    )" || return "$?"

    # get domain plist file
    declare domain_file='/private/var/root/Library/Preferences/com.apple.CoreBrightness.plist'

    # format previous value
    declare previous_value
    previous_value="$(sudo defaults read "$domain_file" "$name" 2>/dev/null)" # failures intentionally ignored
    previous_value="$(sudo /usr/libexec/PlistBuddy -c "Print :${name}" "$domain_file" 2>/dev/null)" # failures intentionally ignored

    # format new value
    plutil -convert xml1 -r -o - -- - <<<"$value" > "$temp_value_format_file" || return "$?"
    declare comparable_value
    comparable_value="$(/usr/libexec/PlistBuddy -c "Print" "$temp_value_format_file")" || return "$?"

    # NOTE: this is pretty dumb, but the order of keys is different, so
    # we need to sort these to be able to compare (is fine as long as we
    # only need to compare these values and nothing else...)
    previous_value="$(sort <<< "$previous_value")" || return "$?"
    comparable_value="$(sort <<< "$comparable_value")" || return "$?"

    # TODO: consider making plist backups somewhere... (only if backup doesn't exist, just so we preserve the originals)
    # ie. defaults export "$backup_plist"

    # write default
    if [[ "$previous_value" != "$comparable_value" ]]; then
        if ! sudo test -f "$domain_file"; then
            # create plist if it doesn't yet exist
            sudo /usr/libexec/PlistBuddy -c 'save' "$domain_file" || return "$?"
            changed='true'
        fi

        # write default
        sudo plutil -replace "$name" -json "$value" "$domain_file" || return "$?"
        changed='true'
    fi
}

night_shift::provision() {
    temp_value_format_file="$(mktemp)"
    on_exit() {
        rm "$temp_value_format_file"
    }
    trap on_exit EXIT

    while read -r state; do
        declare schedule
        schedule="$(jq -r '.schedule' <<< "$state")"

        # provision
        declare status='success'
        declare changed='false'
        declare output=''
        if ! nk::run_for_output output night_shift::_provision_default; then
            status='failed'
        fi

        declare description="night-shift"

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
        night_shift::provision "${@:2}"
        ;;
    *)
        echo "night-shift: unrecognized subcommand ${1}" 1>&2
        exit 1
        ;;
esac
