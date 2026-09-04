pragma ComponentBehavior: Bound
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var values: ({})
    property var numberRanges: ({})
    property var numberDefaults: ({})
    property string cpuScalingDriver: ""
    property string intelPstateStatus: ""
    property string amdPstateStatus: ""
    property string kernelRelease: ""
    property string intelGpuDriver: ""
    property bool rdwProbeDone: false
    property bool rdwAvailable: false

    readonly property var cpuDriverModeKeys: [
        "CPU_DRIVER_OPMODE_ON_AC",
        "CPU_DRIVER_OPMODE_ON_BAT",
        "CPU_DRIVER_OPMODE_ON_SAV"
    ]
    readonly property var intelGpuMinKeys: [
        "INTEL_GPU_MIN_FREQ_ON_AC",
        "INTEL_GPU_MIN_FREQ_ON_BAT",
        "INTEL_GPU_MIN_FREQ_ON_SAV"
    ]
    readonly property var intelGpuMaxKeys: [
        "INTEL_GPU_MAX_FREQ_ON_AC",
        "INTEL_GPU_MAX_FREQ_ON_BAT",
        "INTEL_GPU_MAX_FREQ_ON_SAV"
    ]
    readonly property var intelGpuBoostKeys: [
        "INTEL_GPU_BOOST_FREQ_ON_AC",
        "INTEL_GPU_BOOST_FREQ_ON_BAT",
        "INTEL_GPU_BOOST_FREQ_ON_SAV"
    ]

    function _tokens(text: string): var {
        return String(text ?? "")
            .replace(/[\[\]]/g, "")
            .trim()
            .split(/\s+/)
            .filter(token => token.length > 0)
    }

    function _setValues(keys, entries): void {
        const next = Object.assign({}, root.values)
        for (const key of keys)
            next[key] = Array.from(entries ?? [])
        root.values = next
    }

    function _setNumberRange(keys, minimum: int, maximum: int): void {
        const next = Object.assign({}, root.numberRanges)
        for (const key of keys)
            next[key] = ({ min: minimum, max: maximum })
        root.numberRanges = next
    }

    function _setNumberDefault(keys, value: int): void {
        const next = Object.assign({}, root.numberDefaults)
        for (const key of keys)
            next[key] = value
        root.numberDefaults = next
    }

    function _deleteNumberMetadata(keys): void {
        const ranges = Object.assign({}, root.numberRanges)
        const defaults = Object.assign({}, root.numberDefaults)
        for (const key of keys) {
            delete ranges[key]
            delete defaults[key]
        }
        root.numberRanges = ranges
        root.numberDefaults = defaults
    }

    function _kernelAtLeast(major: int, minor: int): bool {
        const match = String(root.kernelRelease ?? "").match(/^(\d+)\.(\d+)/)
        if (!match)
            return false
        const currentMajor = Number(match[1])
        const currentMinor = Number(match[2])
        return currentMajor > major || (currentMajor === major && currentMinor >= minor)
    }

    function _refreshCpuDriverModes(): void {
        const driver = String(root.cpuScalingDriver ?? "").trim()
        const intelStatus = String(root.intelPstateStatus ?? "").trim()
        const amdStatus = String(root.amdPstateStatus ?? "").trim()
        let modes = []

        // intel_pstate reports scaling_driver=intel_cpufreq in passive mode,
        // so the status ABI is the authoritative capability signal there.
        if (driver === "intel_pstate" || intelStatus === "active" || intelStatus === "passive") {
            modes = ["active", "passive"]
        } else if (driver === "amd-pstate" || driver === "amd-pstate-epp"
                || amdStatus === "active" || amdStatus === "passive" || amdStatus === "guided") {
            modes = ["active", "passive"]
            // guided mode was added to amd-pstate in the kernel 6.4 era. Also
            // retain it on backported kernels already running in guided mode.
            if (amdStatus === "guided" || root._kernelAtLeast(6, 4))
                modes.push("guided")
        }
        root._setValues(root.cpuDriverModeKeys, modes)
    }

    function _clearGpuCapabilities(): void {
        root.intelGpuDriver = ""
        const keys = root.intelGpuMinKeys.concat(root.intelGpuMaxKeys, root.intelGpuBoostKeys)
        root._setValues(keys, [])
        root._deleteNumberMetadata(keys)
    }

    function _applyGpuCapabilities(payload: string): void {
        const parts = String(payload ?? "").trim().split(/\s+/)
        if (parts.length < 3) {
            root._clearGpuCapabilities()
            return
        }
        const driver = parts[0]
        const minimum = Number(parts[1])
        const maximum = Number(parts[2])
        if ((driver !== "i915" && driver !== "xe" && driver !== "mixed")
                || !Number.isFinite(minimum) || !Number.isFinite(maximum)
                || minimum < 0 || maximum < minimum) {
            root._clearGpuCapabilities()
            return
        }

        root.intelGpuDriver = driver
        root._setValues(root.intelGpuMinKeys.concat(root.intelGpuMaxKeys), ["supported"])
        root._setNumberRange(root.intelGpuMinKeys.concat(root.intelGpuMaxKeys), minimum, maximum)
        root._setNumberDefault(root.intelGpuMinKeys, minimum)
        root._setNumberDefault(root.intelGpuMaxKeys, maximum)

        if (driver === "xe") {
            // xe exposes min/max frequency controls but no boost-frequency
            // control through TLP. Keep stale overrides removable, but do not
            // advertise a new boost override that would only be a no-op.
            root._setValues(root.intelGpuBoostKeys, [])
            root._deleteNumberMetadata(root.intelGpuBoostKeys)
        } else {
            root._setValues(root.intelGpuBoostKeys, ["supported"])
            root._setNumberRange(root.intelGpuBoostKeys, minimum, maximum)
            root._setNumberDefault(root.intelGpuBoostKeys, maximum)
        }
    }

    function isRdwSetting(key: string): bool {
        const name = String(key ?? "")
        return name === "DEVICES_TO_DISABLE_ON_LAN_CONNECT"
            || name === "DEVICES_TO_DISABLE_ON_WIFI_CONNECT"
            || name === "DEVICES_TO_DISABLE_ON_WWAN_CONNECT"
            || name === "DEVICES_TO_ENABLE_ON_LAN_DISCONNECT"
            || name === "DEVICES_TO_ENABLE_ON_WIFI_DISCONNECT"
            || name === "DEVICES_TO_ENABLE_ON_WWAN_DISCONNECT"
            || name === "DEVICES_TO_ENABLE_ON_DOCK"
            || name === "DEVICES_TO_DISABLE_ON_DOCK"
            || name === "DEVICES_TO_ENABLE_ON_UNDOCK"
            || name === "DEVICES_TO_DISABLE_ON_UNDOCK"
    }

    function refreshRdw(): void {
        if (!rdwBinaryProbe.running && !rdwDispatcherProbe.running)
            rdwBinaryProbe.running = true
    }

    function refresh(): void {
        governorFile.reload()
        memSleepFile.reload()
        scalingDriverFile.reload()
        intelPstateStatusFile.reload()
        amdPstateStatusFile.reload()
        kernelReleaseFile.reload()
        if (!gpuProbe.running)
            gpuProbe.running = true
        root.refreshRdw()
    }

    FileView {
        id: governorFile
        path: "/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"

        onLoaded: root._setValues([
            "CPU_SCALING_GOVERNOR_ON_AC",
            "CPU_SCALING_GOVERNOR_ON_BAT",
            "CPU_SCALING_GOVERNOR_ON_SAV"
        ], root._tokens(governorFile.text()))

        onLoadFailed: root._setValues([
            "CPU_SCALING_GOVERNOR_ON_AC",
            "CPU_SCALING_GOVERNOR_ON_BAT",
            "CPU_SCALING_GOVERNOR_ON_SAV"
        ], [])
    }

    FileView {
        id: memSleepFile
        path: "/sys/power/mem_sleep"

        onLoaded: root._setValues([
            "MEM_SLEEP_ON_AC",
            "MEM_SLEEP_ON_BAT"
        ], root._tokens(memSleepFile.text()))

        onLoadFailed: root._setValues([
            "MEM_SLEEP_ON_AC",
            "MEM_SLEEP_ON_BAT"
        ], [])
    }

    FileView {
        id: scalingDriverFile
        path: "/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
        onLoaded: {
            root.cpuScalingDriver = scalingDriverFile.text().trim()
            root._refreshCpuDriverModes()
        }
        onLoadFailed: {
            root.cpuScalingDriver = ""
            root._refreshCpuDriverModes()
        }
    }

    FileView {
        id: intelPstateStatusFile
        path: "/sys/devices/system/cpu/intel_pstate/status"
        onLoaded: {
            root.intelPstateStatus = intelPstateStatusFile.text().trim()
            root._refreshCpuDriverModes()
        }
        onLoadFailed: {
            root.intelPstateStatus = ""
            root._refreshCpuDriverModes()
        }
    }

    FileView {
        id: amdPstateStatusFile
        path: "/sys/devices/system/cpu/amd_pstate/status"
        onLoaded: {
            root.amdPstateStatus = amdPstateStatusFile.text().trim()
            root._refreshCpuDriverModes()
        }
        onLoadFailed: {
            root.amdPstateStatus = ""
            root._refreshCpuDriverModes()
        }
    }

    FileView {
        id: kernelReleaseFile
        path: "/proc/sys/kernel/osrelease"
        onLoaded: {
            root.kernelRelease = kernelReleaseFile.text().trim()
            root._refreshCpuDriverModes()
        }
        onLoadFailed: {
            root.kernelRelease = ""
            root._refreshCpuDriverModes()
        }
    }

    Process {
        id: gpuProbe
        command: ["/bin/sh", "-c",
            "global_min=''; global_max=''; has_i915=0; has_xe=0; "
            + "for card in /sys/class/drm/card[0-9]*; do "
            + "[ -e \"$card/device/driver\" ] || continue; "
            + "driver=$(basename \"$(readlink -f \"$card/device/driver\")\"); lo=''; hi=''; "
            + "case \"$driver\" in "
            + "i915) [ -r \"$card/gt_RPn_freq_mhz\" ] && [ -r \"$card/gt_RP0_freq_mhz\" ] || continue; "
            + "lo=$(cat \"$card/gt_RPn_freq_mhz\"); hi=$(cat \"$card/gt_RP0_freq_mhz\"); has_i915=1 ;; "
            + "xe) freqdir=''; for candidate in \"$card\"/device/tile*/gt*/freq*; do "
            + "[ -d \"$candidate\" ] || continue; freqdir=$candidate; break; done; "
            + "[ -n \"$freqdir\" ] && [ -r \"$freqdir/rpn_freq\" ] && [ -r \"$freqdir/rp0_freq\" ] || continue; "
            + "lo=$(cat \"$freqdir/rpn_freq\"); hi=$(cat \"$freqdir/rp0_freq\"); has_xe=1 ;; "
            + "*) continue ;; esac; "
            + "case \"$lo\" in ''|*[!0-9]*) continue ;; esac; case \"$hi\" in ''|*[!0-9]*) continue ;; esac; "
            + "if [ -z \"$global_min\" ] || [ \"$lo\" -gt \"$global_min\" ]; then global_min=$lo; fi; "
            + "if [ -z \"$global_max\" ] || [ \"$hi\" -lt \"$global_max\" ]; then global_max=$hi; fi; done; "
            + "[ -n \"$global_min\" ] && [ -n \"$global_max\" ] && [ \"$global_min\" -le \"$global_max\" ] || exit 1; "
            + "if [ \"$has_i915\" -eq 1 ] && [ \"$has_xe\" -eq 1 ]; then kind=mixed; "
            + "elif [ \"$has_i915\" -eq 1 ]; then kind=i915; elif [ \"$has_xe\" -eq 1 ]; then kind=xe; else exit 1; fi; "
            + "printf '%s\\t%s\\t%s\\n' \"$kind\" \"$global_min\" \"$global_max\""]

        stdout: StdioCollector {
            id: gpuOutput
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0)
                root._applyGpuCapabilities(gpuOutput.text)
            else
                root._clearGpuCapabilities()
        }
    }

    Process {
        id: rdwBinaryProbe
        command: ["/usr/bin/test", "-x", "/usr/bin/tlp-rdw"]

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                rdwDispatcherProbe.running = true
                return
            }
            root.rdwAvailable = false
            root.rdwProbeDone = true
        }
    }

    Process {
        id: rdwDispatcherProbe
        command: ["/usr/bin/systemctl", "is-enabled", "--quiet", "NetworkManager-dispatcher.service"]

        onExited: (exitCode, exitStatus) => {
            root.rdwAvailable = exitCode === 0
            root.rdwProbeDone = true
        }
    }

    Component.onCompleted: root.refresh()

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }
}
