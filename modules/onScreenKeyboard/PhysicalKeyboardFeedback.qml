pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services

Singleton {
    id: root

    // Linux evdev keycodes currently held while the OSK is visible.
    // This state is intentionally ephemeral: no key history or text is logged
    // or persisted anywhere.
    property var pressedKeycodes: []
    property string listenerPath: Quickshell.shellPath("scripts/daemon/osk_physical_key_daemon.py")
    property bool _destroying: false
    property int _restartInterval: 1000

    readonly property bool listening:
        GlobalStates.oskOpen
        && !GlobalStates.screenLocked
        && !Brightness.asleep
        && Quickshell.screens.length > 0

    function _log(...args) {
        if (Quickshell.env("QS_DEBUG") === "1")
            console.log("[PhysicalKeyboardFeedback]", ...args)
    }

    function _clear(): void {
        if (root.pressedKeycodes.length === 0)
            return
        root.pressedKeycodes = []
    }

    function _setPressed(keycode, pressed): void {
        if (isNaN(keycode) || keycode < 0)
            return

        const current = root.pressedKeycodes
        const index = current.indexOf(keycode)

        if (pressed) {
            if (index !== -1)
                return
            root.pressedKeycodes = current.concat([keycode])
            return
        }

        if (index === -1)
            return
        root.pressedKeycodes = current.slice(0, index).concat(current.slice(index + 1))
    }

    function _handleOutput(rawLine): void {
        const line = String(rawLine).trim()
        if (!line.length)
            return

        try {
            const payload = JSON.parse(line)
            if (payload.type === "key") {
                root._setPressed(Number(payload.code), Boolean(payload.pressed))
                return
            }

            if (payload.type === "ready") {
                root._restartInterval = 1000
                root._log("Listening to", Number(payload.devices) || 0, "physical keyboard(s)")
            }
        } catch (error) {
            root._log("Failed to parse evdev output", line, error)
        }
    }

    onListeningChanged: {
        if (root.listening) {
            root._restartInterval = 1000
            if (!keyMonitorProc.running)
                keyMonitorProc.running = true
            return
        }

        keyMonitorRestart.stop()
        if (keyMonitorProc.running)
            keyMonitorProc.running = false
        root._clear()
    }

    Timer {
        id: keyMonitorRestart
        interval: root._restartInterval
        running: false
        repeat: false
        onTriggered: {
            if (!root._destroying && root.listening && !keyMonitorProc.running)
                keyMonitorProc.running = true
        }
    }

    Process {
        id: keyMonitorProc
        running: false
        command: ["/usr/bin/python3", "-u", root.listenerPath]

        stdout: SplitParser {
            onRead: line => root._handleOutput(line)
        }

        stderr: SplitParser {
            onRead: line => root._log("evdev monitor", line)
        }

        onExited: (exitCode, exitStatus) => {
            root._clear()
            if (root._destroying || !root.listening)
                return

            root._log("evdev monitor exited", exitCode, exitStatus)
            keyMonitorRestart.restart()
            root._restartInterval = Math.min(root._restartInterval * 2, 10000)
        }
    }

    Component.onCompleted: {
        if (root.listening)
            keyMonitorProc.running = true
    }

    Component.onDestruction: {
        root._destroying = true
        keyMonitorRestart.stop()
        if (keyMonitorProc.running)
            keyMonitorProc.running = false
        root._clear()
    }
}
