pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property bool available: false
    property bool supported: false
    property bool adjustable: false
    property bool active: false
    property int currentLimit: -1
    property string backend: ""
    property bool busy: false
    readonly property int requestedLimit: Config.options?.battery?.chargeLimit?.threshold ?? 80
    readonly property bool enabled: Config.options?.battery?.chargeLimit?.enable ?? false
    property string _sysfsPath: ""
    property int _rawValue: -1

    function _log(...args): void { if (Quickshell.env("QS_DEBUG") === "1") console.log(...args) }
    function _detect(): void {
        if (!detector.running) {
            root.available = false
            root.supported = false
            root.backend = ""
            detector.running = true
        }
    }
    function _read(): void {
        if (root._sysfsPath.length === 0 || reader.running) return
        reader.command = ["/bin/cat", root._sysfsPath]
        reader.running = true
    }
    function _update(raw: int): void {
        root._rawValue = raw
        switch (root.backend) {
        case "ideapad":
        case "samsung":
            root.active = raw === 1
            root.currentLimit = raw === 1 ? (root.backend === "samsung" ? 80 : -1) : 100
            break
        case "lg":
        case "lg-legacy":
            root.active = raw < 100
            root.currentLimit = raw
            break
        case "sony":
            root.active = raw > 0 && raw < 100
            root.currentLimit = raw
            break
        default:
            root.active = raw > 0 && raw < 100
            root.currentLimit = raw
            break
        }
    }
    function apply(): void {
        if (!root.available || !root.supported || root.busy) return
        root.busy = true
        applyProcess.command = root.enabled
            ? ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--set", String(root.requestedLimit)]
            : ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--disable"]
        applyProcess.running = true
    }
    Component.onCompleted: root._detect()
    Connections {
        target: Config
        function onReadyChanged(): void {
            if (Config.ready) {
                root._detect()
                if (root.enabled) Qt.callLater(() => root.apply())
            }
        }
    }
    Process {
        id: detector
        command: ["/bin/sh", "-c",
            "for p in /sys/bus/platform/drivers/ideapad_acpi/*/conservation_mode; do [ -f \"$p\" ] && printf 'ideapad|%s\\n' \"$p\" && exit 0; done; " +
            "[ -f /sys/devices/platform/samsung/battery_life_extender ] && printf 'samsung|/sys/devices/platform/samsung/battery_life_extender\\n' && exit 0; " +
            "[ -f /sys/devices/platform/lg-laptop/battery_care_limit ] && printf 'lg-legacy|/sys/devices/platform/lg-laptop/battery_care_limit\\n' && exit 0; " +
            "[ -f /sys/devices/platform/sony-laptop/battery_care_limiter ] && printf 'sony|/sys/devices/platform/sony-laptop/battery_care_limiter\\n' && exit 0; " +
            "[ -f /sys/devices/platform/huawei-wmi/charge_control_thresholds ] && printf 'huawei|/sys/devices/platform/huawei-wmi/charge_control_thresholds\\n' && exit 0; " +
            "for p in /sys/devices/platform/smapi/BAT*/stop_charge_thresh; do [ -f \"$p\" ] && printf 'smapi|%s\\n' \"$p\" && exit 0; done; " +
            "for dir in /sys/class/power_supply/*; do [ -d \"$dir\" ] || continue; [ \"$(cat \"$dir/type\" 2>/dev/null)\" = Battery ] || continue; if [ -f \"$dir/present\" ] && [ \"$(cat \"$dir/present\" 2>/dev/null)\" = 0 ]; then continue; fi; for attr in charge_control_end_threshold charge_stop_threshold; do if [ -f \"$dir/$attr\" ]; then printf 'threshold|%s\\n' \"$dir/$attr\"; exit 0; fi; done; done; printf '\\n'"
        ]
        stdout: SplitParser {
            onRead: data => {
                const result = data.trim()
                if (result.length === 0) return
                const parts = result.split("|")
                root.backend = parts[0] ?? ""
                root._sysfsPath = parts[1] ?? ""
                root.available = root.backend.length > 0 && root._sysfsPath.length > 0
                root.supported = root.available
                root.adjustable = root.backend === "threshold" || root.backend === "smapi" || root.backend === "sony" || root.backend === "huawei"
                root._read()
            }
        }
        onExited: {
            if (!root.available) {
                root.supported = false
                root.adjustable = false
            }
        }
    }
    Process {
        id: reader
        stdout: SplitParser {
            onRead: data => {
                const trimmed = data.trim()
                const value = root.backend === "huawei" ? parseInt(trimmed.split(/\s+/).slice(-1)[0]) : parseInt(trimmed)
                if (!isNaN(value)) root._update(value)
            }
        }
    }
    Process {
        id: applyProcess
        onExited: (exitCode, exitStatus) => {
            root.busy = false
            if (exitCode !== 0) console.warn("[TLP] Failed to apply battery charge policy (exit code " + exitCode + ")")
            else root._log("[TLP] Battery charge policy applied")
            root._detect()
        }
    }
    Timer {
        interval: 30000
        repeat: true
        running: root.supported
        onTriggered: root._detect()
    }
}
