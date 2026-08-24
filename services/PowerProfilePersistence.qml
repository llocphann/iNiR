pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.modules.common

Singleton {
    id: root

    property bool _initialized: false
    property bool _tlpProbeDone: false
    property bool _tlpPdManaged: false

    function _profileToString(profile): string {
        switch (profile) {
            case PowerProfile.PowerSaver: return "power-saver"
            case PowerProfile.Balanced: return "balanced"
            case PowerProfile.Performance: return "performance"
        }
        return ""
    }

    function _stringToProfile(value: string): int {
        switch (String(value ?? "").trim()) {
            case "power-saver": return PowerProfile.PowerSaver
            case "balanced": return PowerProfile.Balanced
            case "performance": return PowerProfile.Performance
        }
        return -1
    }

    function _applyPreferredProfile(): void {
        if (!Config.ready || root._initialized || !root._tlpProbeDone)
            return

        root._initialized = true

        // tlp-pd owns automatic profile selection; don't overwrite it with persisted state.
        if (root._tlpPdManaged)
            return

        const restore = Config.options?.powerProfiles?.restoreOnStart ?? true
        const preferred = Config.options?.powerProfiles?.preferredProfile ?? ""

        if (!restore)
            return

        const desired = root._stringToProfile(preferred)
        if (desired < 0)
            return

        if (!PowerProfiles.hasPerformanceProfile && desired === PowerProfile.Performance)
            return

        if (PowerProfiles.profile !== desired) {
            PowerProfiles.profile = desired
        }
    }

    function _probeTlpPd(): void {
        if (!tlpPdProbe.running)
            tlpPdProbe.running = true
    }

    Connections {
        target: Config
        function onReadyChanged(): void {
            if (Config.ready)
                root._probeTlpPd()
        }
    }

    // Also probe when this singleton loads after Config is already ready.
    Component.onCompleted: {
        if (Config.ready)
            root._probeTlpPd()
    }

    Process {
        id: tlpPdProbe
        command: ["/usr/bin/systemctl", "is-enabled", "--quiet", "tlp-pd.service"]
        onExited: (exitCode, exitStatus) => {
            root._tlpPdManaged = exitCode === 0
            root._tlpProbeDone = true
            if (Config.ready)
                Qt.callLater(() => root._applyPreferredProfile())
        }
    }

    // Re-probe if package, migration, or service state changes at runtime.
    Timer {
        interval: 30000
        repeat: true
        running: Config.ready
        onTriggered: root._probeTlpPd()
    }

    Connections {
        target: PowerProfiles
        function onProfileChanged(): void {
            // Don't persist tlp-pd's automatic AC/BAT selection as a user preference.
            if (root._tlpPdManaged)
                return

            const s = root._profileToString(PowerProfiles.profile)
            if (s.length === 0)
                return
            Config.setNestedValue("powerProfiles.preferredProfile", s)
        }
    }
}
