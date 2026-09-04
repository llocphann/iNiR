#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
helper="$repo_root/assets/helpers/inir-battery-charge-limit"
runtime="$repo_root/services/TlpRuntimeCapabilities.qml"
classic="$repo_root/modules/settings/TlpSettingRow.qml"
waffle="$repo_root/modules/waffle/settings/WTlpSettingRow.qml"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    expected=$1
    actual=$2
    message=$3
    [ "$expected" = "$actual" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    needle=$1
    file=$2
    message=$3
    grep -Fq -- "$needle" "$file" || fail "$message"
}

sh -n "$helper" || fail 'TLP helper must remain valid POSIX shell syntax'

# Source the helper under this test basename; its guarded main() must not run.
# shellcheck disable=SC1090
. "$helper"

assert_eq CPU_BOOST_ON_AC \
    "$(tlp_settings_runtime_key CPU_BOOST_ON_AC 1.10.2)" \
    'TLP 1.10 must keep legacy AC profile keys'
assert_eq CPU_BOOST_ON_PRF \
    "$(tlp_settings_runtime_key CPU_BOOST_ON_AC 1.11.0)" \
    'TLP 1.11 must read the canonical PRF profile key'
assert_eq CPU_BOOST_ON_BAL \
    "$(tlp_settings_runtime_key CPU_BOOST_ON_BAT 1.11.0)" \
    'TLP 1.11 must read the canonical BAL profile key'
assert_eq DEVICES_TO_DISABLE_ON_PRF_NOT_IN_USE \
    "$(tlp_settings_runtime_key DEVICES_TO_DISABLE_ON_AC_NOT_IN_USE 1.11.0)" \
    'TLP 1.11 must rename embedded AC profile markers before trailing qualifiers'
assert_eq DEVICES_TO_DISABLE_ON_BAL_NOT_IN_USE \
    "$(tlp_settings_runtime_key DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE 1.11.0)" \
    'TLP 1.11 must rename embedded BAT profile markers before trailing qualifiers'
assert_eq TLP_PROFILE_AC \
    "$(tlp_settings_runtime_key TLP_PROFILE_AC 1.11.0)" \
    'profile selection keys are not suffix-renamed settings'

assert_contains 'CPU_DRIVER_OPMODE_ON_AC' "$runtime" \
    'runtime capabilities must gate CPU driver modes'
assert_contains '/sys/devices/system/cpu/intel_pstate/status' "$runtime" \
    'intel_pstate passive mode must remain detectable'
assert_contains '_kernelAtLeast(6, 4)' "$runtime" \
    'guided amd-pstate mode must be kernel-gated'
assert_contains 'INTEL_GPU_MIN_FREQ_ON_AC' "$runtime" \
    'runtime capabilities must probe Intel GPU frequency support'
assert_contains 'numberRanges' "$runtime" \
    'runtime capabilities must expose hardware number ranges'

for row in "$classic" "$waffle"; do
    assert_contains 'gpuFrequencyGroupKeys' "$row" \
        "$(basename "$row") must stage Intel GPU frequency groups atomically"
    assert_contains 'editorNumberRange' "$row" \
        "$(basename "$row") must use runtime numeric bounds"
    assert_contains 'next.length === 0 && root.settingKey.startsWith("PLATFORM_PROFILE_")' "$row" \
        "$(basename "$row") must turn an empty TLP 1.11 profile list into inherit/unset"
done

printf '%s\n' '1..1'
printf '%s\n' 'ok 1 - TLP UI capability guards and TLP 1.11 key compatibility are present'
