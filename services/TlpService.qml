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

    property string _status: ""
    property string _plugin: ""

    readonly property var _fixedPlugins: [
        "lenovo", "lenovo-legacy", "lg", "lg-legacy",
        "macbook", "samsung", "sony", "toshiba"
    ]

    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1") console.log(...args)
    }

    function _detect(): void {
        if (detector.running) return
        detector.running = true
    }

    function _parseStatus(): void {
        const text = root._status
        const pluginMatch = text.match(/(?:^|\n)Plugin:\s*([^\n]+)/)
        const featuresMatch = text.match(/(?:^|\n)Supported features:\s*([^\n]+)/)

        root._plugin = pluginMatch ? pluginMatch[1].trim() : ""
        const features = featuresMatch ? featuresMatch[1].trim().toLowerCase() : ""
        const hasChargeControl = features.includes("charge threshold") || features.includes("charge thresholds") || features.includes("charge type")

        root.available = pluginMatch !== null
        root.supported = hasChargeControl
        root.backend = root._plugin
        root.adjustable = hasChargeControl && root._fixedPlugins.indexOf(root._plugin) < 0

        if (!root.supported) {
            root.active = false
            root.currentLimit = -1
            return
        }

        // TLP is the authority. Raw sysfs attributes are deliberately not used
        // for capability detection because TLP can expose them on an unsupported
        // generic plugin.
        const thresholdPatterns = [
            /charge_control_end_threshold\s*=\s*(\d+)\s*\[%\]/,
            /battery_care_limit\s*=\s*(\d+)\s*\[%\]/,
            /battery_care_limiter\s*=\s*(\d+)\s*\[%\]/,
            /stop_charge_thresh\s*=\s*(\d+)\s*\[%\]/
        ]

        let value = -1
        for (const pattern of thresholdPatterns) {
            const match = text.match(pattern)
            if (match) {
                value = parseInt(match[1])
                break
            }
        }

        if (root._plugin === "samsung") {
            const match = text.match(/battery_life_extender\s*=\s*(\d+)/)
            if (match) value = parseInt(match[1]) === 1 ? 80 : 100
        } else if (root._plugin === "lenovo") {
            const match = text.match(/charge_types\s*=.*\[Long_Life\]/)
            root.active = match !== null
            root.currentLimit = root.active ? -1 : 100
            return
        }

        root.currentLimit = value
        root.active = value > 0 && value < 100
    }

    function apply(): void {
        if (!root.supported || root.busy) return

        root.busy = true
        applyProcess.command = root.enabled
            ? ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--set", String(root.requestedLimit)]
            : ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--disable"]
        applyProcess.running = true
    }

    Component.onCompleted: _detect()

    Connections {
        target: Config

        function onReadyChanged(): void {
            if (Config.ready) {
                root._detect()
                if (root.enabled)
                    Qt.callLater(() => root.apply())
            }
        }
    }

    Process {
        id: detector
        command: ["/usr/bin/tlp-stat", "-b"]

        stdout: SplitParser {
            onRead: data => {
                root._status += data + "\n"
            }
        }

        onStarted: {
            root._status = ""
            root.available = false
            root.supported = false
            root.adjustable = false
            root.active = false
            root.currentLimit = -1
            root.backend = ""
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.available = false
                root.supported = false
                root.adjustable = false
                root.active = false
                root.currentLimit = -1
                root.backend = ""
                return
            }
            root._parseStatus()
        }
    }

    Process {
        id: applyProcess

        onExited: (exitCode, exitStatus) => {
            root.busy = false
            if (exitCode !== 0)
                console.warn("[TLP] Failed to apply battery charge policy (exit code " + exitCode + ")")
            else
                root._log("[TLP] Battery charge policy applied")

            root._detect()
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.available
        onTriggered: root._detect()
    }
}
