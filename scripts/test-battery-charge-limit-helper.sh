#!/bin/sh

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
helper="$repo_root/assets/helpers/inir-battery-charge-limit"
installed_helper=${INIR_TLP_HELPER:-/usr/libexec/inir-battery-charge-limit}
live_tmp=""

live_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

live_usage() {
    printf '%s\n' 'Live lifecycle checks (run as the desktop user):'
    printf '%s\n' '  test-battery-charge-limit-helper.sh --live-restart'
    printf '%s\n' '  test-battery-charge-limit-helper.sh --live-display'
    printf '%s\n' '  test-battery-charge-limit-helper.sh --live-suspend'
    printf '%s\n' ''
    printf '%s\n' '--live-display waits while you turn the display off and wake it.'
    printf '%s\n' '--live-suspend requires typing SUSPEND before invoking systemctl suspend.'
}

live_file_fingerprint() {
    local path=$1 checksum metadata

    if [ ! -e "$path" ]; then
        printf 'missing\n'
        return 0
    fi
    [ -f "$path" ] || {
        printf 'not-a-regular-file\n'
        return 0
    }
    checksum=$(sha256sum "$path" 2>/dev/null | awk '{ print $1 }') || return 1
    metadata=$(stat -Lc '%d:%i:%s:%Y:%Z:%a:%U:%G' "$path" 2>/dev/null) || return 1
    printf '%s %s\n' "$checksum" "$metadata"
}

live_capture() {
    local destination=$1

    mkdir -p "$destination" || return 1
    "$installed_helper" --status > "$destination/charge.json" || return 1
    "$installed_helper" --config-status > "$destination/settings.json" || return 1
    jq -e '.schema == 1' "$destination/charge.json" >/dev/null || return 1
    jq -e '.schema == 1' "$destination/settings.json" >/dev/null || return 1
    live_file_fingerprint /etc/tlp.d/99-inir-battery-charge-limit.conf \
        > "$destination/battery-dropin.fingerprint" || return 1
    live_file_fingerprint /etc/tlp.d/99-inir-tlp-settings.conf \
        > "$destination/settings-dropin.fingerprint" || return 1
    systemctl is-active tlp.service > "$destination/tlp-service" 2>/dev/null || true
}

live_wait_for_status() {
    local attempts=0

    while [ "$attempts" -lt 40 ]; do
        if "$installed_helper" --status > "$live_tmp/wait-charge.json" 2>/dev/null \
            && "$installed_helper" --config-status > "$live_tmp/wait-settings.json" 2>/dev/null \
            && jq -e '.schema == 1' "$live_tmp/wait-charge.json" >/dev/null \
            && jq -e '.schema == 1' "$live_tmp/wait-settings.json" >/dev/null \
            && jq -e '
                if .managed == true and .supported == true and .stateKnown == true
                then (.currentLimit == .managedLimit and
                    (.managedStart == null or .currentStart == .managedStart))
                else true
                end
            ' "$live_tmp/wait-charge.json" >/dev/null; then
                return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

live_compare() {
    local before=$1 after=$2 before_service after_service
    local before_charge after_charge before_settings after_settings

    cmp -s "$before/battery-dropin.fingerprint" "$after/battery-dropin.fingerprint" || {
        live_fail 'battery-care drop-in was rewritten or replaced during the lifecycle event'
        return 1
    }
    cmp -s "$before/settings-dropin.fingerprint" "$after/settings-dropin.fingerprint" || {
        live_fail 'general TLP settings drop-in was rewritten or replaced during the lifecycle event'
        return 1
    }

    before_charge=$(jq -Sc '{managed, managedBattery, managedStart, managedLimit}' "$before/charge.json") || return 1
    after_charge=$(jq -Sc '{managed, managedBattery, managedStart, managedLimit}' "$after/charge.json") || return 1
    [ "$before_charge" = "$after_charge" ] || {
        live_fail 'iNiR battery-care ownership changed during the lifecycle event'
        return 1
    }

    before_settings=$(jq -Sc '.managed' "$before/settings.json") || return 1
    after_settings=$(jq -Sc '.managed' "$after/settings.json") || return 1
    [ "$before_settings" = "$after_settings" ] || {
        live_fail 'iNiR general TLP overrides changed during the lifecycle event'
        return 1
    }

    if jq -e '.managed == true and .supported == true and .stateKnown == true' "$after/charge.json" >/dev/null; then
        jq -e '
            .currentLimit == .managedLimit and
            (.managedStart == null or .currentStart == .managedStart)
        ' "$after/charge.json" >/dev/null || {
            live_fail 'managed battery thresholds did not recover after the lifecycle event'
            return 1
        }
    fi

    before_service=$(cat "$before/tlp-service")
    after_service=$(cat "$after/tlp-service")
    if [ "$before_service" = active ] && [ "$after_service" != active ]; then
        live_fail 'tlp.service was active before the event but is not active afterwards'
        return 1
    fi

    printf '%s\n' 'ok - TLP ownership, drop-ins and effective charge limit remained consistent'
    printf 'charge:  %s\n' "$after_charge"
    printf 'settings: %s\n' "$after_settings"
    printf 'service:  %s\n' "${after_service:-unknown}"
}

run_live_lifecycle() {
    local event=$1 launcher reply

    [ "$(id -u)" -ne 0 ] || live_fail 'run live lifecycle checks as the desktop user, not root' || return 1
    [ -x "$installed_helper" ] || live_fail "installed helper is missing: $installed_helper" || return 1
    command -v jq >/dev/null 2>&1 || live_fail 'jq is required' || return 1
    command -v sha256sum >/dev/null 2>&1 || live_fail 'sha256sum is required' || return 1

    live_tmp=$(mktemp -d) || return 1
    trap '[ -z "${live_tmp:-}" ] || rm -rf -- "$live_tmp"' EXIT
    trap '[ -z "${live_tmp:-}" ] || rm -rf -- "$live_tmp"; exit 1' HUP INT TERM

    live_capture "$live_tmp/before" || live_fail 'could not capture the pre-event TLP state' || return 1
    jq -e '
        if .managed == true and .supported == true and .stateKnown == true
        then (.currentLimit == .managedLimit and
            (.managedStart == null or .currentStart == .managedStart))
        else true
        end
    ' "$live_tmp/before/charge.json" >/dev/null || {
        live_fail 'the battery policy is already out of sync; wait for iNiR reconciliation before testing a lifecycle event'
        return 1
    }

    case "$event" in
        restart)
            if command -v inir >/dev/null 2>&1; then
                launcher=$(command -v inir)
            else
                launcher="$repo_root/scripts/inir"
            fi
            [ -x "$launcher" ] || live_fail 'could not resolve the iNiR launcher' || return 1
            printf '%s\n' 'Restarting Quickshell through iNiR...'
            "$launcher" restart || live_fail 'iNiR restart failed' || return 1
            sleep 5
            ;;
        display)
            printf '%s\n' 'Turn the display off, wait a few seconds, then wake it again.' > /dev/tty
            printf '%s' 'Type DONE after the display is awake: ' > /dev/tty
            IFS= read -r reply < /dev/tty || return 1
            [ "$reply" = DONE ] || live_fail 'display lifecycle check cancelled' || return 1
            sleep 2
            ;;
        suspend)
            printf '%s\n' 'This will suspend the machine. Save open work first.' > /dev/tty
            printf '%s' 'Type SUSPEND to continue: ' > /dev/tty
            IFS= read -r reply < /dev/tty || return 1
            [ "$reply" = SUSPEND ] || live_fail 'suspend lifecycle check cancelled' || return 1
            systemctl suspend || live_fail 'system suspend failed' || return 1
            sleep 5
            ;;
        *) live_usage; return 2 ;;
    esac

    live_wait_for_status || live_fail 'TLP status did not become readable after the event' || return 1
    live_capture "$live_tmp/after" || live_fail 'could not capture the post-event TLP state' || return 1
    live_compare "$live_tmp/before" "$live_tmp/after"
}

case "${1:-}" in
    --live-restart) run_live_lifecycle restart; exit $? ;;
    --live-display) run_live_lifecycle display; exit $? ;;
    --live-suspend) run_live_lifecycle suspend; exit $? ;;
    --live-help) live_usage; exit 0 ;;
esac

# The helper deliberately exposes no privileged test mode. Source its functions
# under this different basename and replace only the hardware/TLP boundaries.
# shellcheck disable=SC1090
. "$helper"

suite_tmp=$(mktemp -d)
trap 'rm -rf -- "$suite_tmp"' EXIT
trap 'rm -rf -- "$suite_tmp"; exit 1' HUP INT TERM

tests_run=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    return 1
}

assert_eq() {
    local expected=$1 actual=$2 message=$3
    [ "$expected" = "$actual" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    local needle=$1 file=$2 message=$3
    grep -Fq -- "$needle" "$file" || fail "$message"
}

assert_not_contains() {
    local needle=$1 file=$2 message=$3
    if grep -Fq -- "$needle" "$file"; then
        fail "$message"
    fi
}

reset_case() {
    case_dir=$(mktemp -d "$suite_tmp/case.XXXXXX")
    config_dir="$case_dir/etc/tlp.d"
    config_file="$config_dir/99-inir-battery-charge-limit.conf"
    tlp_settings_config_file="$config_dir/99-inir-tlp-settings.conf"
    tlp_settings_schema="$repo_root/assets/tlp/tlp-settings-schema.json"
    tlp_settings_lock="$case_dir/inir-tlp-settings.lock"
    platform_profile_choices_file="$case_dir/platform_profile_choices"
    mkdir -p "$config_dir"
    printf '%s\n' 'performance balanced low-power balanced-performance quiet cool' > "$platform_profile_choices_file"

    test_version=1.10.2
    export test_version
    test_enabled=1
    test_plugin=dell
    test_method=natacpi
    test_variant=1
    test_battery=BAT1
    test_config_battery=BAT1
    test_start_values=""
    test_stop_values=""
    test_behavior=success
    test_fullcharge_rc=0
    test_runtime_available=1
    test_probe_rc=0
    test_config_probe_rc=0

    state_start="$case_dir/current-start"
    state_stop="$case_dir/current-stop"
    calls_file="$case_dir/start-calls"
    resume_calls_file="$case_dir/resume-calls"
    printf '95\n' > "$state_start"
    printf '100\n' > "$state_stop"
    printf '0\n' > "$calls_file"
    printf '0\n' > "$resume_calls_file"

    tlp_bin="$case_dir/tlp"
    printf '%s\n' '#!/bin/sh' "printf 'TLP version %s\\n' \"\$test_version\"" > "$tlp_bin"
    chmod 0755 "$tlp_bin"

    tmp_file=""
    backup_file=""
    had_config=0
    tlp_settings_tmp_file=""
    tlp_settings_backup_file=""
    tlp_settings_had_config=0
}

find_tlp_runtime() {
    if [ "$test_runtime_available" -ne 1 ]; then
        tlp_bin=""
        tlp_lib_dir=""
        return 1
    fi
    tlp_bin="$case_dir/tlp"
    tlp_lib_dir=/test/tlp-runtime
    return 0
}

run_probe() {
    [ "$test_probe_rc" -eq 0 ] || return "$test_probe_rc"
    printf 'version=%s\n' "$test_version"
    printf 'enabled=%s\n' "$test_enabled"
    [ "$test_enabled" -eq 1 ] || return 0
    printf 'plugin=%s\n' "$test_plugin"
    printf 'method=%s\n' "$test_method"
    printf 'variant=%s\n' "$test_variant"
    if [ "$test_method" != none ]; then
        printf 'battery=%s\n' "$test_battery"
        printf 'config_battery=%s\n' "$test_config_battery"
        printf 'current_start=%s\n' "$(cat "$state_start")"
        printf 'current_stop=%s\n' "$(cat "$state_stop")"
        printf 'start_values=%s\n' "$test_start_values"
        printf 'stop_values=%s\n' "$test_stop_values"
    fi
}

run_tlp_settings_probe() {
    local line key value effective_enabled

    [ "$test_config_probe_rc" -eq 0 ] || return "$test_config_probe_rc"
    effective_enabled=$test_enabled
    if [ -f "$tlp_settings_config_file" ]; then
        value=$(sed -n 's/^TLP_ENABLE="\([01]\)"$/\1/p' "$tlp_settings_config_file" | tail -n 1)
        [ -z "$value" ] || effective_enabled=$value
    fi
    printf 'meta\tversion\t%s\n' "$test_version"
    printf 'meta\tenabled\t%s\n' "$effective_enabled"
    printf 'setting\tTLP_ENABLE\t%s\n' "$effective_enabled"
    printf 'setting\tCPU_BOOST_ON_BAT\t0\n'
    printf 'setting\tSOUND_POWER_SAVE_ON_BAT\t1\n'

    [ -f "$tlp_settings_config_file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            *) continue ;;
        esac
        printf 'setting\t%s\t%s\n' "$key" "$value"
    done < "$tlp_settings_config_file"
}

apply_staged_state() {
    local value

    value=$(sed -n 's/^START_CHARGE_THRESH_BAT[01]=//p' "$config_file" | tail -n 1)
    [ -z "$value" ] || printf '%s\n' "$value" > "$state_start"
    value=$(sed -n 's/^STOP_CHARGE_THRESH_BAT[01]=//p' "$config_file" | tail -n 1)
    [ -z "$value" ] || printf '%s\n' "$value" > "$state_stop"
}

run_tlp_start() {
    local calls
    calls=$(( $(cat "$calls_file") + 1 ))
    printf '%s\n' "$calls" > "$calls_file"

    case "$test_behavior" in
        silent-error-once)
            if [ "$calls" -eq 1 ]; then
                printf '%s\n' 'Error in configuration at START_CHARGE_THRESH_BAT1="0": Battery skipped.'
                printf '%s\n' 'TLP started'
                return 0
            fi
            ;;
        mismatch-once)
            if [ "$calls" -eq 1 ]; then
                apply_staged_state
                printf '%s\n' "$(( $(cat "$state_stop") + 1 ))" > "$state_stop"
                printf '%s\n' 'TLP started'
                return 0
            fi
            ;;
        fail-once)
            if [ "$calls" -eq 1 ]; then
                printf '%s\n' 'TLP failed'
                return 1
            fi
            ;;
    esac

    [ ! -f "$config_file" ] || apply_staged_state
    printf '%s\n' 'TLP started'
    return 0
}

run_tlp_fullcharge() {
    [ "$test_fullcharge_rc" -eq 0 ] || return "$test_fullcharge_rc"
    printf '95\n' > "$state_start"
    printf '100\n' > "$state_stop"
    printf '%s\n' 'Full charge thresholds restored'
}

simulate_tlp_resume() {
    local calls

    calls=$(( $(cat "$resume_calls_file") + 1 ))
    printf '%s\n' "$calls" > "$resume_calls_file"

    # TLP owns suspend/resume. Its system-sleep hook re-reads the persistent
    # configuration and applies the relevant profile. Hardware which needs
    # threshold restoration sees the same iNiR-owned drop-in at resume time.
    [ ! -f "$config_file" ] || apply_staged_state
}

test_status_uses_tlp_plugin_metadata() {
    reset_case
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT1=80' > "$config_file"
    printf '50\n' > "$state_start"
    printf '80\n' > "$state_stop"

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .schema == 1 and
        .available == true and
        .supported == true and
        .plugin == "dell" and
        .configBattery == "BAT1" and
        .limitKind == "continuous" and
        .minimumLimit == 55 and
        .maximumLimit == 100 and
        .currentStart == 50 and
        .currentLimit == 80 and
        .managed == true
    ' >/dev/null || fail 'Dell status JSON does not match TLP metadata'
}

test_generic_plugin_fails_closed() {
    reset_case
    test_plugin=generic
    test_method=none

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == true and
        .supported == false and
        .reason == "charge-control-unsupported"
    ' >/dev/null || fail 'generic plugin must not advertise charge control'
}

test_unsupported_tlp_version_fails_closed() {
    reset_case
    test_version=2.0.0

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == true and
        .supported == false and
        .reason == "unsupported-tlp-version"
    ' >/dev/null || fail 'unknown TLP versions must fail closed'
}

test_disabled_tlp_fails_closed() {
    reset_case
    test_enabled=0
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT1=80' > "$config_file"

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == true and
        .supported == false and
        .managed == true and
        .reason == "tlp-disabled"
    ' >/dev/null || fail 'a disabled TLP must fail closed without hiding iNiR ownership'
}

test_unreadable_tlp_config_fails_closed() {
    reset_case
    test_probe_rc=73

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == true and
        .supported == false and
        .reason == "tlp-config-unavailable"
    ' >/dev/null || fail 'an unreadable TLP config must not fall through to defaults'
}

test_runtime_unavailable_is_reported_without_failure() {
    reset_case
    test_runtime_available=0

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == false and
        .supported == false and
        .stateKnown == false and
        .reason == "tlp-unavailable"
    ' >/dev/null || fail 'missing TLP must be a valid, non-mutating status result'
}

test_missing_battery_preserves_managed_ownership() {
    reset_case
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT1=80' > "$config_file"
    test_probe_rc=72

    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .available == true and
        .supported == false and
        .managed == true and
        .reason == "battery-unavailable"
    ' >/dev/null || fail 'a removed battery must not hide iNiR drop-in ownership'
}

test_plugin_capability_classes() {
    reset_case
    test_plugin=asus
    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .limitKind == "continuous" and .minimumLimit == 1 and .maximumLimit == 100
    ' >/dev/null || fail 'ASUS must expose its 1..100 stop range'

    reset_case
    test_plugin=msi
    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .limitKind == "continuous" and .minimumLimit == 10 and .maximumLimit == 100
    ' >/dev/null || fail 'MSI must expose its 10..100 stop range'

    reset_case
    test_plugin=lenovo
    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .limitKind == "mode" and .adjustable == false and
        .allowedLimits == [0, 1] and .fixedLimit == 1
    ' >/dev/null || fail 'Lenovo must expose conservation mode, not percentages'

    reset_case
    test_plugin=sony
    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .limitKind == "discrete" and .adjustable == true and
        .allowedLimits == [50, 80, 100]
    ' >/dev/null || fail 'Sony must expose its discrete thresholds'

    reset_case
    test_plugin=cros-ec
    test_variant=1
    output=$(status)
    printf '%s\n' "$output" | jq -e '
        .limitKind == "continuous" and .minimumLimit == 1 and .maximumLimit == 100
    ' >/dev/null || fail 'cros-ec v2 must expose stop-only continuous control'
}

test_dell_derives_valid_start_and_bat1_key() {
    reset_case

    set_policy 80 >/dev/null 2>&1 || fail 'Dell policy should apply'
    assert_contains 'START_CHARGE_THRESH_BAT1=50' "$config_file" 'Dell must use its minimum valid start threshold'
    assert_contains 'STOP_CHARGE_THRESH_BAT1=80' "$config_file" 'Dell must target the TLP-selected BAT1 key'
    assert_not_contains 'RESTORE_THRESHOLDS_ON_BAT' "$config_file" 'iNiR must not override the user restore setting'
    assert_eq 644 "$(stat -c '%a' "$config_file")" 'managed policy mode must be 0644'
}

test_valid_current_start_is_preserved() {
    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '60\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'ThinkPad policy should apply'
    assert_contains 'START_CHARGE_THRESH_BAT0=60' "$config_file" 'valid current start threshold should be preserved'
}

test_tuxedo_uses_runtime_discrete_sets() {
    reset_case
    test_plugin=tuxedo
    test_start_values='40 50 60 70 80 95'
    test_stop_values='60 70 80 90 100'

    set_policy 70 >/dev/null 2>&1 || fail 'TUXEDO discrete policy should apply'
    assert_contains 'START_CHARGE_THRESH_BAT1=40' "$config_file" 'TUXEDO should choose a compatible runtime start value'
    assert_contains 'STOP_CHARGE_THRESH_BAT1=70' "$config_file" 'TUXEDO should write the selected runtime stop value'

    rm -f -- "$config_file"
    if set_policy 85 >/dev/null 2>&1; then
        fail 'TUXEDO must reject values outside its runtime set'
    fi
    [ ! -f "$config_file" ] || fail 'invalid discrete values must not create a policy'
}

test_fixed_mode_normalizes_hidden_threshold() {
    reset_case
    test_plugin=macbook

    set_policy 73 >/dev/null 2>&1 || fail 'fixed MacBook mode should ignore a stale hidden percentage'
    assert_contains 'STOP_CHARGE_THRESH_BAT1=80' "$config_file" 'MacBook conservation mode must use 80'
    assert_not_contains 'START_CHARGE_THRESH' "$config_file" 'derived start thresholds must not be owned by iNiR'
}

test_silent_tlp_error_rolls_back() {
    reset_case
    printf '%s\n' '# prior policy' 'START_CHARGE_THRESH_BAT1=50' 'STOP_CHARGE_THRESH_BAT1=90' > "$config_file"
    cp "$config_file" "$case_dir/expected"
    printf '50\n' > "$state_start"
    printf '90\n' > "$state_stop"
    test_behavior=silent-error-once

    if set_policy 80 >/dev/null 2>&1; then
        fail 'zero-exit TLP configuration errors must fail the transaction'
    fi
    cmp -s "$case_dir/expected" "$config_file" || fail 'silent TLP errors must restore the previous policy'
}

test_post_apply_mismatch_rolls_back() {
    reset_case
    printf '%s\n' '# prior policy' 'START_CHARGE_THRESH_BAT1=50' 'STOP_CHARGE_THRESH_BAT1=90' > "$config_file"
    cp "$config_file" "$case_dir/expected"
    printf '50\n' > "$state_start"
    printf '90\n' > "$state_stop"
    test_behavior=mismatch-once

    if set_policy 80 >/dev/null 2>&1; then
        fail 'post-apply hardware mismatch must fail the transaction'
    fi
    cmp -s "$case_dir/expected" "$config_file" || fail 'hardware mismatch must restore the previous policy'
}

test_disable_treats_fullcharge_as_best_effort() {
    reset_case
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT1=80' > "$config_file"
    test_fullcharge_rc=1

    disable_policy >/dev/null 2>&1 || fail 'fullcharge failure alone must not retain iNiR ownership'
    [ ! -e "$config_file" ] || fail 'disable must remove the iNiR drop-in'
}

test_legacy_read_signatures_use_api_mode() {
    calls_file="$suite_tmp/read-signature-calls"
    : > "$calls_file"

    batdrv_read_threshold() {
        printf '%s\n' "$*" >> "$calls_file"
        printf '80'
    }

    _batdrv_plugin=asus
    _natacpi=1
    read_probe_thresholds
    assert_eq 80 "$current_stop" 'ASUS stop threshold should be read'
    assert_eq 0 "$(cat "$calls_file")" 'ASUS read API takes one verbosity argument'

    : > "$calls_file"
    _batdrv_plugin=toshiba
    read_probe_thresholds
    assert_eq 80 "$current_stop" 'Toshiba stop threshold should be read'
    assert_eq 0 "$(cat "$calls_file")" 'Toshiba read API takes one verbosity argument'
}

test_tlp_settings_status_reads_effective_and_managed_values() {
    reset_case
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        'CPU_BOOST_ON_BAT="1"' > "$tlp_settings_config_file"

    output=$(tlp_settings_status)
    printf '%s\n' "$output" | jq -e '
        .schema == 1 and
        .available == true and
        .supported == true and
        .configAvailable == true and
        .enabled == true and
        .tlpVersion == "1.10.2" and
        .effective.CPU_BOOST_ON_BAT == "1" and
        .managed.CPU_BOOST_ON_BAT == "1" and
        .runtimeValues.PLATFORM_PROFILE_ON_AC ==
            ["performance", "balanced", "low-power", "balanced-performance", "quiet", "cool"] and
        .runtimeValues.PLATFORM_PROFILE_ON_BAT == .runtimeValues.PLATFORM_PROFILE_ON_AC and
        .runtimeValues.PLATFORM_PROFILE_ON_SAV == .runtimeValues.PLATFORM_PROFILE_ON_AC
    ' >/dev/null || fail 'TLP settings status must expose effective ownership and runtime platform choices'
}

test_tlp_settings_apply_batches_validated_overrides() {
    reset_case

    tlp_settings_apply \
        --set CPU_BOOST_ON_BAT 1 \
        --set SOUND_POWER_SAVE_ON_BAT 12 >/dev/null 2>&1 || fail 'valid TLP overrides should apply'

    assert_contains 'CPU_BOOST_ON_BAT="1"' "$tlp_settings_config_file" 'CPU override must be written'
    assert_contains 'SOUND_POWER_SAVE_ON_BAT="12"' "$tlp_settings_config_file" 'audio override must be written'
    assert_not_contains 'CHARGE_THRESH' "$tlp_settings_config_file" 'general settings must not own charge thresholds'
    assert_eq 644 "$(stat -c '%a' "$tlp_settings_config_file")" 'TLP settings drop-in mode must be 0644'
    assert_eq 1 "$(cat "$calls_file")" 'a batch must restart TLP only once'
}

test_tlp_settings_accepts_documented_keep_and_userspace() {
    reset_case

    tlp_settings_apply \
        --set DISK_APM_LEVEL_ON_AC 'keep 254' \
        --set DISK_SPINDOWN_TIMEOUT_ON_BAT '_ keep' \
        --set DISK_IOSCHED 'keep mq-deadline' \
        --set CPU_SCALING_GOVERNOR_ON_AC userspace >/dev/null 2>&1 \
        || fail 'TLP-documented keep/_ values and userspace governor should apply'

    assert_contains 'DISK_APM_LEVEL_ON_AC="keep 254"' "$tlp_settings_config_file" \
        'disk APM must preserve TLP keep semantics'
    assert_contains 'DISK_SPINDOWN_TIMEOUT_ON_BAT="_ keep"' "$tlp_settings_config_file" \
        'disk spin-down must accept the documented underscore synonym'
    assert_contains 'DISK_IOSCHED="keep mq-deadline"' "$tlp_settings_config_file" \
        'I/O scheduler must accept keep next to an explicit scheduler'
    assert_contains 'CPU_SCALING_GOVERNOR_ON_AC="userspace"' "$tlp_settings_config_file" \
        'CPU governor validation must include userspace'
}

test_tlp_profile_apply_migrates_legacy_config_syntax() {
    reset_case
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        "CPU_BOOST_ON_BAT='1'" > "$tlp_settings_config_file"

    tlp_settings_apply \
        --set TLP_PROFILE_AC PRF \
        --set TLP_PROFILE_BAT SAV \
        --set TLP_PROFILE_DEFAULT AC >/dev/null 2>&1 \
        || fail 'TLP profile mappings should apply'

    assert_contains 'CPU_BOOST_ON_BAT="1"' "$tlp_settings_config_file" \
        'Apply must migrate a legacy iNiR override to TLP-compatible quoting'
    assert_contains 'TLP_PROFILE_AC="PRF"' "$tlp_settings_config_file" \
        'AC profile mapping must be written'
    assert_contains 'TLP_PROFILE_BAT="SAV"' "$tlp_settings_config_file" \
        'battery profile mapping must be written'
    assert_contains 'TLP_PROFILE_DEFAULT="AC"' "$tlp_settings_config_file" \
        'fallback profile mapping must retain its legacy alias'
    assert_not_contains "='" "$tlp_settings_config_file" \
        'the managed drop-in must not retain TLP-invalid single quotes'

    output=$(tlp_settings_status)
    printf '%s\n' "$output" | jq -e '
        .managed.TLP_PROFILE_AC == "PRF" and
        .managed.TLP_PROFILE_BAT == "SAV" and
        .managed.TLP_PROFILE_DEFAULT == "AC" and
        .effective.TLP_PROFILE_AC == "PRF" and
        .effective.TLP_PROFILE_BAT == "SAV" and
        .effective.TLP_PROFILE_DEFAULT == "AC"
    ' >/dev/null || fail 'profile mappings must survive effective-config verification'
    assert_eq 1 "$(cat "$calls_file")" 'all profile mappings must run tlp start once'
}

test_tlp_settings_reject_unknown_unsafe_and_version_gated_values() {
    reset_case

    if tlp_settings_apply --set NOT_A_TLP_SETTING 1 >/dev/null 2>&1; then
        fail 'unknown settings must be rejected'
    fi
    if tlp_settings_apply --set CPU_BOOST_ON_BAT '1;touch /tmp/nope' >/dev/null 2>&1; then
        fail 'unsafe shell values must be rejected'
    fi
    if tlp_settings_apply --set SOUND_POWER_SAVE_ON_BAT 99999 >/dev/null 2>&1; then
        fail 'out-of-range numeric values must be rejected'
    fi
    if tlp_settings_apply --set DEVICES_TO_DISABLE_ON_AC wifi >/dev/null 2>&1; then
        fail 'TLP 1.11-only settings must be rejected on TLP 1.10'
    fi
    [ ! -e "$tlp_settings_config_file" ] || fail 'rejected values must not create a settings drop-in'
}

test_tlp_settings_unset_preserves_other_overrides() {
    reset_case

    tlp_settings_apply --set CPU_BOOST_ON_BAT 1 --set SOUND_POWER_SAVE_ON_BAT 12 >/dev/null 2>&1 || fail 'initial TLP overrides should apply'
    tlp_settings_apply --unset CPU_BOOST_ON_BAT >/dev/null 2>&1 || fail 'unsetting one TLP override should apply'

    assert_not_contains 'CPU_BOOST_ON_BAT=' "$tlp_settings_config_file" 'unset must remove only the selected key'
    assert_contains 'SOUND_POWER_SAVE_ON_BAT="12"' "$tlp_settings_config_file" 'unset must preserve unrelated overrides'
}

test_tlp_settings_silent_error_rolls_back() {
    reset_case
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        'CPU_BOOST_ON_BAT="0"' > "$tlp_settings_config_file"
    cp "$tlp_settings_config_file" "$case_dir/expected-settings"
    test_behavior=silent-error-once

    if tlp_settings_apply --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1; then
        fail 'silent TLP settings errors must fail the transaction'
    fi
    cmp -s "$case_dir/expected-settings" "$tlp_settings_config_file" || fail 'silent TLP settings errors must restore the prior drop-in'
}

test_tlp_settings_disable_skips_tlp_start() {
    reset_case

    tlp_settings_apply --set TLP_ENABLE 0 >/dev/null 2>&1 || fail 'TLP_ENABLE=0 should be saved'
    assert_contains 'TLP_ENABLE="0"' "$tlp_settings_config_file" 'disabled state must be owned explicitly'
    assert_eq 0 "$(cat "$calls_file")" 'TLP start must be skipped after disabling TLP'
}

test_tlp_platform_profiles_follow_runtime_choices() {
    reset_case
    printf '%s\n' 'performance balanced low-power quiet' > "$platform_profile_choices_file"

    tlp_settings_apply --set PLATFORM_PROFILE_ON_AC quiet >/dev/null 2>&1 \
        || fail 'TLP 1.10 should accept a vendor profile advertised by the kernel ABI'
    assert_contains 'PLATFORM_PROFILE_ON_AC="quiet"' "$tlp_settings_config_file" \
        'TLP 1.10 must preserve the runtime-advertised vendor profile'

    reset_case
    printf '%s\n' 'performance balanced low-power' > "$platform_profile_choices_file"
    if tlp_settings_apply --set PLATFORM_PROFILE_ON_AC vendor-ultra >/dev/null 2>&1; then
        fail 'TLP 1.10 must reject a platform profile which is not available at runtime'
    fi
    [ ! -e "$tlp_settings_config_file" ] || fail 'a rejected TLP 1.10 profile must not create an override'

    reset_case
    test_version=1.11.0-alpha.0
    printf '%s\n' 'performance balanced low-power quiet' > "$platform_profile_choices_file"
    tlp_settings_apply --set PLATFORM_PROFILE_ON_BAT 'vendor-ultra quiet' >/dev/null 2>&1 \
        || fail 'TLP 1.11 should allow ordered fallback lists when at least one value is locally available'
    assert_contains 'PLATFORM_PROFILE_ON_BAT="vendor-ultra quiet"' "$tlp_settings_config_file" \
        'TLP 1.11 must retain the ordered fallback list verbatim'

    reset_case
    test_version=1.11.0-alpha.0
    printf '%s\n' 'performance balanced low-power' > "$platform_profile_choices_file"
    if tlp_settings_apply --set PLATFORM_PROFILE_ON_BAT 'vendor-ultra silent-max' >/dev/null 2>&1; then
        fail 'TLP 1.11 must reject a fallback list with no runtime match'
    fi

    # A stale iNiR-owned value must stay readable after firmware capabilities
    # change; otherwise the user could be locked out of the UI needed to unset it.
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        'PLATFORM_PROFILE_ON_AC="old-vendor"' > "$tlp_settings_config_file"
    output=$(tlp_settings_status)
    printf '%s\n' "$output" | jq -e '
        .configAvailable == true and
        .managed.PLATFORM_PROFILE_ON_AC == "old-vendor" and
        .runtimeValues.PLATFORM_PROFILE_ON_AC == ["performance", "balanced", "low-power"]
    ' >/dev/null || fail 'stale platform-profile ownership must remain observable and removable'
}

test_tlp_settings_reset_preserves_battery_policy() {
    reset_case
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT1=80' > "$config_file"
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        'CPU_BOOST_ON_BAT="1"' > "$tlp_settings_config_file"

    tlp_settings_reset >/dev/null 2>&1 || fail 'general TLP overrides should reset'
    [ ! -e "$tlp_settings_config_file" ] || fail 'reset must remove the general iNiR drop-in'
    [ -f "$config_file" ] || fail 'reset must preserve the separate battery-care policy'
}

test_tlp_settings_batch_applies_charge_and_overrides_once() {
    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    tlp_settings_apply \
        --charge-set 80 \
        --set CPU_BOOST_ON_BAT 1 \
        --set SOUND_POWER_SAVE_ON_BAT 12 >/dev/null 2>&1 \
        || fail 'charge care and general settings should apply as one transaction'

    assert_contains 'START_CHARGE_THRESH_BAT0=0' "$config_file" \
        'batch apply must write the TLP-derived start threshold'
    assert_contains 'STOP_CHARGE_THRESH_BAT0=80' "$config_file" \
        'batch apply must write the requested stop threshold'
    assert_contains 'CPU_BOOST_ON_BAT="1"' "$tlp_settings_config_file" \
        'batch apply must write general overrides'
    assert_contains 'SOUND_POWER_SAVE_ON_BAT="12"' "$tlp_settings_config_file" \
        'batch apply must retain every staged override'
    assert_eq 80 "$(cat "$state_stop")" 'batch apply must verify the hardware threshold'
    assert_eq 1 "$(cat "$calls_file")" 'charge care and general settings must run tlp start once'
}

test_tlp_settings_batch_disables_charge_and_keeps_overrides() {
    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'initial charge policy should apply'
    printf '0\n' > "$calls_file"

    tlp_settings_apply --charge-disable --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1 \
        || fail 'charge disable and general overrides should share one transaction'

    [ ! -e "$config_file" ] || fail 'batch disable must remove charge-policy ownership'
    assert_contains 'CPU_BOOST_ON_BAT="1"' "$tlp_settings_config_file" \
        'batch disable must preserve the staged general override'
    assert_eq 100 "$(cat "$state_stop")" 'batch disable must restore full-charge hardware state'
    assert_eq 1 "$(cat "$calls_file")" 'batch disable must run tlp start once'
}

test_tlp_settings_batch_disable_keeps_fullcharge_best_effort() {
    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'initial charge policy should apply'
    printf '0\n' > "$calls_file"
    test_fullcharge_rc=1

    tlp_settings_apply --charge-disable --set CPU_BOOST_ON_BAT 1 \
        > "$case_dir/batch-disable-output" 2>&1 \
        || fail 'fullcharge failure alone must not fail a mixed disable transaction'

    [ ! -e "$config_file" ] || fail 'best-effort batch disable must remove charge-policy ownership'
    assert_contains 'CPU_BOOST_ON_BAT="1"' "$tlp_settings_config_file" \
        'best-effort batch disable must preserve the staged general override'
    assert_contains 'Warning: TLP could not restore vendor full-charge thresholds' \
        "$case_dir/batch-disable-output" \
        'best-effort batch disable must report the hardware reset warning'
    assert_eq 1 "$(cat "$calls_file")" \
        'best-effort batch disable must still apply the remaining TLP configuration once'
}

test_tlp_settings_batch_rolls_back_both_dropins() {
    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '%s\n' \
        '# Managed by iNiR. Do not edit manually.' \
        '# Battery/backend detected by TLP: BAT0 (thinkpad)' \
        'START_CHARGE_THRESH_BAT0=0' \
        'STOP_CHARGE_THRESH_BAT0=90' > "$config_file"
    printf '%s\n' \
        '# Managed by iNiR TLP Settings. Do not edit manually.' \
        'CPU_BOOST_ON_BAT="0"' > "$tlp_settings_config_file"
    cp "$config_file" "$case_dir/expected-charge"
    cp "$tlp_settings_config_file" "$case_dir/expected-settings"
    printf '0\n' > "$state_start"
    printf '90\n' > "$state_stop"
    test_behavior=silent-error-once

    if tlp_settings_apply --charge-set 80 --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1; then
        fail 'a rejected mixed batch must fail'
    fi

    cmp -s "$case_dir/expected-charge" "$config_file" \
        || fail 'mixed-batch rollback must restore the charge drop-in'
    cmp -s "$case_dir/expected-settings" "$tlp_settings_config_file" \
        || fail 'mixed-batch rollback must restore the settings drop-in'
    assert_eq 90 "$(cat "$state_stop")" 'mixed-batch rollback must restore hardware state'
    assert_eq 2 "$(cat "$calls_file")" 'mixed-batch rollback must re-apply the previous policy once'
}

test_tlp_settings_ui_uses_schema_groups_and_batched_apply() {
    settings_service="$repo_root/services/TlpSettingsService.qml"
    runtime_service="$repo_root/services/TlpRuntimeCapabilities.qml"
    services_qmldir="$repo_root/services/qmldir"
    classic_page="$repo_root/modules/settings/TlpConfig.qml"
    waffle_page="$repo_root/modules/waffle/settings/pages/WTlpPage.qml"
    schema="$repo_root/assets/tlp/tlp-settings-schema.json"

    jq -e '
        .schema == 1 and
        ([.categories[].settings[]] | length) == 125 and
        ([.categories[].groups[]] | length) == 62 and
        ([.categories[].groups[] |
            select(.description == "" or (.description | contains("\n")) or (.description | length) > 120)] | length) == 0 and
        .descriptionAttribution.license == "GPL-2.0-or-later"
    ' "$schema" >/dev/null || fail 'the UI schema must expose concise setting groups'

    assert_contains 'singleton TlpRuntimeCapabilities 1.0 TlpRuntimeCapabilities.qml' "$services_qmldir" \
        'runtime capability service must be registered'
    assert_contains '/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors' "$runtime_service" \
        'CPU governor choices must come from the kernel'
    assert_contains '/sys/power/mem_sleep' "$runtime_service" \
        'suspend choices must come from the kernel'
    assert_contains 'function groupsForCategory(category, filterText): var {' "$settings_service" \
        'settings service must expose grouped schema data'
    assert_contains 'command.push("--charge-set"' "$settings_service" \
        'charge care must join the same privileged batch'
    assert_eq 1 "$(grep -Fc 'const command = ["/usr/bin/pkexec", root.helperPath, "--config-apply"]' "$settings_service")" \
        'settings service must build one privileged Apply command' || return 1
    assert_not_contains 'applyOnLeave' "$settings_service" \
        'settings service must require explicit Apply'
    assert_contains 'settingsPageName: Translation.tr("Battery")' "$classic_page" \
        'classic Battery page must remain registered'
    assert_contains 'pageTitle: Translation.tr("Battery")' "$waffle_page" \
        'Waffle Battery page must remain registered'
    assert_contains 'model: root.visibleGroups' "$classic_page" \
        'classic page must render schema groups'
    assert_contains 'model: root.visibleGroups' "$waffle_page" \
        'Waffle page must render schema groups'
    assert_contains 'onClicked: TlpSettingsService.apply()' "$classic_page" \
        'classic page must expose explicit Apply'
    assert_contains 'onButtonClicked: TlpSettingsService.apply()' "$waffle_page" \
        'Waffle page must expose explicit Apply'
}

test_quickshell_lifecycle_contract_is_status_driven() {
    charge_service="$repo_root/services/TlpService.qml"
    settings_service="$repo_root/services/TlpSettingsService.qml"

    assert_contains 'if (root._matchesRequestedPolicy()) {' "$charge_service" \
        'Quickshell startup must skip mutation when the requested policy already matches'
    assert_contains 'command: ["/usr/libexec/inir-battery-charge-limit", "--status"]' "$charge_service" \
        'battery lifecycle detection must use the unprivileged status command'
    assert_contains 'onTriggered: root._detect()' "$charge_service" \
        'battery lifecycle timer must remain detection-only'
    assert_contains 'command: [root.helperPath, "--config-status"]' "$settings_service" \
        'general TLP lifecycle detection must use the unprivileged status command'
    assert_contains 'onTriggered: root.refresh()' "$settings_service" \
        'general TLP lifecycle timer must remain refresh-only'
    assert_not_contains 'systemctl suspend' "$charge_service" \
        'Quickshell must not take ownership of TLP suspend/resume'
    assert_not_contains 'power-off-monitors' "$charge_service" \
        'display power events must not mutate TLP from the battery service'
    assert_not_contains 'systemctl suspend' "$settings_service" \
        'the TLP settings UI must not take ownership of suspend/resume'
    assert_not_contains 'power-off-monitors' "$settings_service" \
        'display power events must not mutate TLP from the settings service'
}

test_startup_timer_and_display_polling_are_read_only() {
    local before_calls iteration charge_output settings_output

    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'initial battery policy should apply'
    tlp_settings_apply --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1 \
        || fail 'initial general TLP override should apply'
    cp "$config_file" "$case_dir/expected-battery-policy"
    cp "$tlp_settings_config_file" "$case_dir/expected-settings-policy"
    before_calls=$(cat "$calls_file")

    iteration=0
    while [ "$iteration" -lt 8 ]; do
        charge_output=$(status)
        printf '%s\n' "$charge_output" | jq -e '
            .supported == true and .managed == true and .stateKnown == true and
            .configBattery == "BAT0" and .managedBattery == "BAT0" and
            .currentLimit == 80 and .managedLimit == 80
        ' >/dev/null || fail 'status polling must keep a matching battery policy observable'

        settings_output=$(tlp_settings_status)
        printf '%s\n' "$settings_output" | jq -e '
            .configAvailable == true and .managed.CPU_BOOST_ON_BAT == "1" and
            .effective.CPU_BOOST_ON_BAT == "1"
        ' >/dev/null || fail 'status polling must keep general overrides observable'
        iteration=$((iteration + 1))
    done

    cmp -s "$case_dir/expected-battery-policy" "$config_file" \
        || fail 'startup/timer/display polling must not rewrite the battery drop-in'
    cmp -s "$case_dir/expected-settings-policy" "$tlp_settings_config_file" \
        || fail 'startup/timer/display polling must not rewrite the settings drop-in'
    assert_eq "$before_calls" "$(cat "$calls_file")" \
        'startup/timer/display polling must not invoke tlp start'
}

test_tlp_resume_preserves_persistent_inir_policies() {
    local before_calls charge_output settings_output

    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'initial battery policy should apply'
    tlp_settings_apply --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1 \
        || fail 'initial general TLP override should apply'
    cp "$config_file" "$case_dir/pre-sleep-battery-policy"
    cp "$tlp_settings_config_file" "$case_dir/pre-sleep-settings-policy"
    before_calls=$(cat "$calls_file")

    simulate_tlp_resume

    cmp -s "$case_dir/pre-sleep-battery-policy" "$config_file" \
        || fail 'TLP resume must not rewrite the persistent battery drop-in'
    cmp -s "$case_dir/pre-sleep-settings-policy" "$tlp_settings_config_file" \
        || fail 'TLP resume must not rewrite the persistent settings drop-in'
    assert_eq "$before_calls" "$(cat "$calls_file")" \
        'TLP resume must not be represented as an iNiR tlp start mutation'
    assert_eq 1 "$(cat "$resume_calls_file")" 'the simulated TLP resume hook must run once'

    charge_output=$(status)
    printf '%s\n' "$charge_output" | jq -e \
        '.managed == true and .active == true and .currentLimit == 80 and .managedLimit == 80' \
        >/dev/null || fail 'battery policy must remain effective after resume'
    settings_output=$(tlp_settings_status)
    printf '%s\n' "$settings_output" | jq -e \
        '.managed.CPU_BOOST_ON_BAT == "1" and .effective.CPU_BOOST_ON_BAT == "1"' \
        >/dev/null || fail 'general TLP override must remain effective after resume'
}

test_post_resume_hardware_drift_is_repaired_transactionally() {
    local drift_output repaired_output

    reset_case
    test_plugin=thinkpad
    test_battery=BAT0
    test_config_battery=BAT0
    printf '0\n' > "$state_start"

    set_policy 80 >/dev/null 2>&1 || fail 'initial battery policy should apply'
    cp "$config_file" "$case_dir/pre-drift-policy"

    # Simulate firmware restoring full-charge thresholds after resume.
    printf '99\n' > "$state_start"
    printf '100\n' > "$state_stop"
    drift_output=$(status)
    printf '%s\n' "$drift_output" | jq -e \
        '.managed == true and .stateKnown == true and
         .currentStart == 99 and .managedStart == 0 and
         .currentLimit == 100 and .managedLimit == 80' \
        >/dev/null || fail 'post-resume hardware drift must be observable'

    set_policy 80 >/dev/null 2>&1 || fail 'post-resume policy repair should apply'
    cmp -s "$case_dir/pre-drift-policy" "$config_file" \
        || fail 'repairing hardware drift must retain the same persistent policy'
    assert_eq 2 "$(cat "$calls_file")" 'post-resume drift repair must use one additional tlp start'

    repaired_output=$(status)
    printf '%s\n' "$repaired_output" | jq -e \
        '.managed == true and .active == true and
         .currentStart == 0 and .managedStart == 0 and
         .currentLimit == 80 and .managedLimit == 80' \
        >/dev/null || fail 'post-resume repair must be verified from hardware state'
}

test_disabled_policy_stays_absent_across_runtime_events() {
    local before_calls charge_output settings_output

    reset_case
    set_policy 80 >/dev/null 2>&1 || fail 'initial battery policy should apply'
    disable_policy >/dev/null 2>&1 || fail 'battery policy should disable'
    [ ! -e "$config_file" ] || fail 'disabled battery policy must have no owned drop-in'

    tlp_settings_apply --set CPU_BOOST_ON_BAT 1 >/dev/null 2>&1 \
        || fail 'general TLP overrides should remain independently usable'
    cp "$tlp_settings_config_file" "$case_dir/disabled-settings-policy"
    before_calls=$(cat "$calls_file")

    status >/dev/null
    tlp_settings_status >/dev/null
    simulate_tlp_resume
    status >/dev/null
    tlp_settings_status >/dev/null

    [ ! -e "$config_file" ] \
        || fail 'restart, display polling and resume must not resurrect a disabled battery policy'
    cmp -s "$case_dir/disabled-settings-policy" "$tlp_settings_config_file" \
        || fail 'battery disable lifecycle must preserve unrelated general overrides'
    assert_eq "$before_calls" "$(cat "$calls_file")" \
        'read-only lifecycle events must not invoke an additional tlp start'

    charge_output=$(status)
    printf '%s\n' "$charge_output" | jq -e '.managed == false' >/dev/null \
        || fail 'disabled battery policy must remain unmanaged after resume'
    settings_output=$(tlp_settings_status)
    printf '%s\n' "$settings_output" | jq -e '.managed.CPU_BOOST_ON_BAT == "1"' >/dev/null \
        || fail 'general TLP override must survive the disabled battery lifecycle'
}

test_source_install_lifecycle() {
    stage="$suite_tmp/install-stage"
    helper_path="$stage/usr/libexec/inir-battery-charge-limit"
    policy_path="$stage/usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy"
    dropin_path="$stage/etc/tlp.d/99-inir-battery-charge-limit.conf"
    settings_dropin_path="$stage/etc/tlp.d/99-inir-tlp-settings.conf"
    schema_path="$stage/usr/share/inir/tlp-settings-schema.json"

    make -s -C "$repo_root" install-battery-helper DESTDIR="$stage" || fail 'source install target failed'
    [ -x "$helper_path" ] || fail 'source install must install the executable helper'
    [ -f "$policy_path" ] || fail 'source install must install the polkit action'
    [ -f "$schema_path" ] || fail 'source install must install the root-owned TLP schema'
    assert_eq 755 "$(stat -c '%a' "$helper_path")" 'installed helper mode must be 0755'
    assert_eq 644 "$(stat -c '%a' "$policy_path")" 'installed policy mode must be 0644'
    assert_eq 644 "$(stat -c '%a' "$schema_path")" 'installed schema mode must be 0644'

    mkdir -p "$(dirname "$dropin_path")"
    printf '%s\n' 'STOP_CHARGE_THRESH_BAT0=80' > "$dropin_path"
    printf '%s\n' 'CPU_BOOST_ON_BAT="1"' > "$settings_dropin_path"
    make -s -C "$repo_root" uninstall-battery-helper DESTDIR="$stage" || fail 'source uninstall target failed'
    [ ! -e "$helper_path" ] || fail 'source uninstall must remove the helper'
    [ ! -e "$policy_path" ] || fail 'source uninstall must remove the polkit action'
    [ ! -e "$dropin_path" ] || fail 'source uninstall must remove the iNiR-owned TLP drop-in'
    [ ! -e "$settings_dropin_path" ] || fail 'source uninstall must remove the iNiR-owned settings drop-in'
    [ ! -e "$schema_path" ] || fail 'source uninstall must remove the root-owned TLP schema'
}

run_test() {
    local name=$1
    shift
    tests_run=$((tests_run + 1))
    if "$@"; then
        printf 'ok %s - %s\n' "$tests_run" "$name"
    else
        exit 1
    fi
}

printf '1..37\n'
run_test 'status uses TLP plugin metadata' test_status_uses_tlp_plugin_metadata
run_test 'generic plugin fails closed' test_generic_plugin_fails_closed
run_test 'unsupported TLP version fails closed' test_unsupported_tlp_version_fails_closed
run_test 'disabled TLP fails closed' test_disabled_tlp_fails_closed
run_test 'unreadable TLP config fails closed' test_unreadable_tlp_config_fails_closed
run_test 'missing TLP is reported safely' test_runtime_unavailable_is_reported_without_failure
run_test 'missing battery preserves managed ownership' test_missing_battery_preserves_managed_ownership
run_test 'plugin capability classes are vendor-specific' test_plugin_capability_classes
run_test 'Dell derives valid BAT1 policy' test_dell_derives_valid_start_and_bat1_key
run_test 'valid start threshold is preserved' test_valid_current_start_is_preserved
run_test 'TUXEDO uses discrete runtime sets' test_tuxedo_uses_runtime_discrete_sets
run_test 'fixed modes normalize hidden threshold' test_fixed_mode_normalizes_hidden_threshold
run_test 'silent TLP errors roll back' test_silent_tlp_error_rolls_back
run_test 'post-apply mismatch rolls back' test_post_apply_mismatch_rolls_back
run_test 'disable keeps fullcharge best-effort' test_disable_treats_fullcharge_as_best_effort
run_test 'legacy plugin reads use API signatures' test_legacy_read_signatures_use_api_mode
run_test 'TLP settings status reports effective ownership and runtime choices' test_tlp_settings_status_reads_effective_and_managed_values
run_test 'TLP settings apply batches validated overrides' test_tlp_settings_apply_batches_validated_overrides
run_test 'TLP settings accept documented keep and userspace values' test_tlp_settings_accepts_documented_keep_and_userspace
run_test 'TLP profile apply migrates legacy quoting' test_tlp_profile_apply_migrates_legacy_config_syntax
run_test 'TLP settings reject invalid inputs and versions' test_tlp_settings_reject_unknown_unsafe_and_version_gated_values
run_test 'TLP settings unset preserves other overrides' test_tlp_settings_unset_preserves_other_overrides
run_test 'TLP settings silent errors roll back' test_tlp_settings_silent_error_rolls_back
run_test 'TLP settings disable skips start' test_tlp_settings_disable_skips_tlp_start
run_test 'TLP platform profiles follow runtime choices' test_tlp_platform_profiles_follow_runtime_choices
run_test 'TLP settings reset preserves battery policy' test_tlp_settings_reset_preserves_battery_policy
run_test 'TLP settings batch charge and overrides once' test_tlp_settings_batch_applies_charge_and_overrides_once
run_test 'TLP settings batch charge disable and overrides' test_tlp_settings_batch_disables_charge_and_keeps_overrides
run_test 'TLP settings batch disable keeps fullcharge best-effort' test_tlp_settings_batch_disable_keeps_fullcharge_best_effort
run_test 'TLP settings batch rolls back both drop-ins' test_tlp_settings_batch_rolls_back_both_dropins
run_test 'TLP settings UI exposes grouped batched controls' test_tlp_settings_ui_uses_schema_groups_and_batched_apply
run_test 'Quickshell lifecycle contract is status-driven' test_quickshell_lifecycle_contract_is_status_driven
run_test 'startup timer and display polling are read-only' test_startup_timer_and_display_polling_are_read_only
run_test 'TLP resume preserves persistent iNiR policies' test_tlp_resume_preserves_persistent_inir_policies
run_test 'post-resume hardware drift is repaired transactionally' test_post_resume_hardware_drift_is_repaired_transactionally
run_test 'disabled policy stays absent across runtime events' test_disabled_policy_stays_absent_across_runtime_events
run_test 'source install lifecycle owns exact artifacts' test_source_install_lifecycle
