pragma ComponentBehavior: Bound
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var values: ({})
    property bool rdwProbeDone: false
    property bool rdwAvailable: false

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
