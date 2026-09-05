pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

GeneralConfigCore {
    id: root

    // Static search entries use human-facing section names while the System
    // navigator uses stable lowercase task ids. Keep the translation here so
    // search can land on the correct tab before it scrolls to a control.
    function activateSettingsSearchSection(section: string): void {
        const value = String(section ?? "").toLowerCase()
        if (value.includes("power") || value.includes("battery")
                || value.includes("charge") || value.includes("tlp")) {
            root.activeSection = "power"
        } else if (value.includes("audio") || value.includes("sound")) {
            root.activeSection = "audio"
        } else if (value.includes("language") || value.includes("locale")
                || value.includes("time")) {
            root.activeSection = "locale"
        } else if (value.includes("input") || value.includes("keyboard")) {
            root.activeSection = "input"
        } else if (value.includes("safety") || value.includes("polic")) {
            root.activeSection = "safety"
        }
    }

    // TLP now belongs to System → Power. It is appended to the inherited
    // ContentPage so there is one scroll surface and no nested Flickable.
    TlpPowerSettings {
        Layout.fillWidth: true
        visible: root.activeSection === "power"
    }
}
