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

        // When tlp-pd is enabled it owns profile selection, including AC/BAT
        // automatic switching. Restoring iNiR's last observed profile here
        // would turn an automatically selected TLP profile into a forced one
        // on the next shell start.
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

    // Covers the path where Config was already ready before this singleton was
    // instantiated (hot-reload or deferred loading after Config.ready fired).
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

    // Migrations, package updates, or manual service changes can enable/disable
    // tlp-pd while the shell stays alive. Re-probe read-only state so profile
    // persistence never keeps acting on a stale startup decision.
    Timer {
        interval: 30000
        repeat: true
        running: Config.ready
        onTriggered: root._probeTlpPd()
    }

    Connections {
        target: PowerProfiles
        function onProfileChanged(): void {
            // TLP/tlp-pd owns this state when enabled; do not persist its
            // automatically selected AC/BAT profile as iNiR's user preference.
            if (root._tlpPdManaged)
                return

            const s = root._profileToString(PowerProfiles.profile)
            if (s.length === 0)
                return
            Config.setNestedValue("powerProfiles.preferredProfile", s)
        }
    }
}
