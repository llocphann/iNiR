pragma ComponentBehavior: Bound
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

Singleton {
    id: root

    property bool available: false
    property bool supported: false
    property bool adjustable: false
    property bool stateKnown: false
    property bool active: false
    property bool managed: false
    property int currentLimit: -1
    property int currentStart: -1
    property string backend: ""
    property string tlpVersion: ""
    property string statusReason: ""
    property string limitKind: "none"
    property int minimumLimit: 1
    property int maximumLimit: 100
    property int limitStepSize: 1
    property var allowedLimits: []
    property int fixedLimit: -1
    property string configBattery: ""
    property string managedBattery: ""
    property int managedLimit: -1
    property bool busy: false

    // Nested JsonAdapter assignments do not emit reliable per-property change
    // notifications. Depend on Config.revision explicitly so a settings-window
    // write is observed by this process immediately (including disable).
    readonly property int requestedLimit: {
        void Config.revision
        return Config.options?.battery?.chargeLimit?.threshold ?? 80
    }
    readonly property int effectiveRequestedLimit: root._normalizeRequestedLimit(root.requestedLimit)
    readonly property bool enabled: {
        void Config.revision
        return Config.options?.battery?.chargeLimit?.enable ?? false
    }
    readonly property bool discrete: root.limitKind === "discrete"
    readonly property bool continuous: root.limitKind === "continuous"

    property bool _statusSeen: false
    property bool _reconcileAfterDetect: false
    property bool _redetectAfterCurrent: false

    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1") console.log(...args)
    }

    function _clearStatus(): void {
        root.available = false
        root.supported = false
        root.adjustable = false
        root.stateKnown = false
        root.active = false
        root.managed = false
        root.currentLimit = -1
        root.currentStart = -1
        root.backend = ""
        root.tlpVersion = ""
        root.statusReason = ""
        root.limitKind = "none"
        root.minimumLimit = 1
        root.maximumLimit = 100
        root.limitStepSize = 1
        root.allowedLimits = []
        root.fixedLimit = -1
        root.configBattery = ""
        root.managedBattery = ""
        root.managedLimit = -1
    }

    function _detect(): void {
        if (!detector.running)
            detector.running = true
    }

    function refresh(): void {
        if (detector.running) {
            root._redetectAfterCurrent = true
            return
        }
        root._detect()
    }

    function _numberOr(value, fallback: int): int {
        return typeof value === "number" && isFinite(value) ? Math.round(value) : fallback
    }

    function _normalizeRequestedLimit(value: int): int {
        const requested = Number(value)

        if ((root.limitKind === "fixed" || root.limitKind === "mode") && root.fixedLimit >= 0)
            return root.fixedLimit

        if (root.limitKind === "continuous") {
            const minimum = root.minimumLimit >= 0 ? root.minimumLimit : 1
            const maximum = root.maximumLimit >= minimum ? root.maximumLimit : 100
            const step = Math.max(1, root.limitStepSize)
            const clamped = Math.max(minimum, Math.min(maximum, requested))
            return Math.max(minimum, Math.min(maximum,
                minimum + Math.round((clamped - minimum) / step) * step))
        }

        if (root.limitKind === "discrete" && root.allowedLimits.length > 0) {
            let nearest = Number(root.allowedLimits[0])
            let distance = Math.abs(nearest - requested)
            for (let index = 1; index < root.allowedLimits.length; ++index) {
                const candidate = Number(root.allowedLimits[index])
                const candidateDistance = Math.abs(candidate - requested)
                if (candidateDistance < distance) {
                    nearest = candidate
                    distance = candidateDistance
                }
            }
            return nearest
        }

        return isFinite(requested) ? Math.round(requested) : 80
    }

    function _parseStatus(line: string): void {
        let data
        try {
            data = JSON.parse(String(line ?? "").trim())
        } catch (error) {
            root._clearStatus()
            return
        }

        if (data?.schema !== 1) {
            root._clearStatus()
            return
        }

        root.available = data.available === true
        root.supported = data.supported === true
        root.adjustable = data.adjustable === true
        root.stateKnown = data.stateKnown === true
        root.active = data.active === true
        root.currentLimit = root._numberOr(data.currentLimit, -1)
        root.currentStart = root._numberOr(data.currentStart, -1)
        root.backend = String(data.plugin ?? "")
        root.tlpVersion = String(data.tlpVersion ?? "")
        root.statusReason = String(data.reason ?? "")
        root.limitKind = String(data.limitKind ?? "none")
        root.minimumLimit = root._numberOr(data.minimumLimit, 1)
        root.maximumLimit = root._numberOr(data.maximumLimit, 100)
        root.limitStepSize = Math.max(1, root._numberOr(data.stepSize, 1))
        root.allowedLimits = Array.isArray(data.allowedLimits)
            ? data.allowedLimits.filter(value => typeof value === "number" && isFinite(value)).map(value => Math.round(value))
            : []
        root.fixedLimit = root._numberOr(data.fixedLimit, -1)
        root.configBattery = String(data.configBattery ?? "")
        root.managedBattery = String(data.managedBattery ?? "")
        root.managedLimit = root._numberOr(data.managedLimit, -1)
        root.managed = data.managed === true
        root._statusSeen = true
    }

    function _matchesRequestedPolicy(): bool {
        // Disabled means iNiR must stop owning a TLP drop-in. A charge limit
        // from the user's own TLP configuration may legitimately remain active.
        if (!root.enabled)
            return !root.managed

        if (!root.supported || !root.managed || !root.stateKnown)
            return false

        if (root.managedBattery !== root.configBattery)
            return false
        if (root.managedLimit !== root.effectiveRequestedLimit)
            return false

        return root.currentLimit === root.effectiveRequestedLimit
    }

    function apply(): void {
        if (!Config.ready)
            return

        // Preserve the latest requested config change while a privileged apply
        // or status refresh is already in flight. One reconciliation runs later.
        if (root.busy || detector.running) {
            root._reconcileAfterDetect = true
            return
        }

        if (root._matchesRequestedPolicy()) {
            root._reconcileAfterDetect = false
            root._log("[TLP] Battery charge policy already matches iNiR ownership/state")
            return
        }

        // Enabling requires a battery-care interface. Disabling only requires
        // iNiR to own a drop-in, even if the battery was removed in the meantime.
        if (root.enabled && !root.supported) {
            root._reconcileAfterDetect = false
            return
        }
        if (!root.enabled && !root.managed) {
            root._reconcileAfterDetect = false
            return
        }

        root._reconcileAfterDetect = false
        root.busy = true
        applyProcess.command = root.enabled
            ? ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--set", String(root.effectiveRequestedLimit)]
            : ["/usr/bin/pkexec", "/usr/libexec/inir-battery-charge-limit", "--disable"]
        applyProcess.running = true
    }

    Component.onCompleted: {
        root._reconcileAfterDetect = Config.ready
        root._detect()
    }

    Connections {
        target: Config

        function onConfigChanged(): void {
            // Let revision-dependent bindings settle before comparing the
            // requested policy with the last hardware status.
            Qt.callLater(() => root.apply())
        }

        function onReadyChanged(): void {
            if (!Config.ready)
                return
            root._reconcileAfterDetect = true
            root._detect()
        }
    }

    Process {
        id: detector
        command: ["/usr/libexec/inir-battery-charge-limit", "--status"]

        stdout: SplitParser {
            onRead: data => root._parseStatus(data)
        }

        onStarted: root._statusSeen = false

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 || !root._statusSeen) {
                root._clearStatus()
                if (root._redetectAfterCurrent) {
                    root._redetectAfterCurrent = false
                    Qt.callLater(() => root._detect())
                } else {
                    root._reconcileAfterDetect = false
                }
                return
            }

            if (root._redetectAfterCurrent) {
                root._redetectAfterCurrent = false
                Qt.callLater(() => root._detect())
                return
            }

            const reconcile = root._reconcileAfterDetect
            root._reconcileAfterDetect = false
            if (reconcile)
                Qt.callLater(() => root.apply())
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

            // Always refresh from the non-privileged status path. If config
            // changed while pkexec was active, keep the pending reconciliation.
            root._detect()
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root._detect()
    }
}
