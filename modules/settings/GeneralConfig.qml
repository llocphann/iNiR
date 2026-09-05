pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services

GeneralConfigCore {
    id: root

    function selectTlpCategory(categoryId: string): bool {
        const wanted = String(categoryId ?? "")
        const categories = TlpSettingsService._array(TlpSettingsService.navigationCategories)
        for (let i = 0; i < categories.length; i++) {
            if (String(categories[i]?.id ?? "") !== wanted)
                continue
            // Search navigation is presentation-only, so it is safe to switch
            // the visible category even while an Apply transaction is busy.
            tlpPowerSettings.selectedCategoryIndex = i
            return true
        }
        return false
    }

    // Static search entries use human-facing section names while the System
    // navigator uses stable lowercase task ids. Keep the translation here so
    // search can land on the correct tab before it scrolls to a control.
    function activateSettingsSearchSection(section: string): void {
        const value = String(section ?? "").toLowerCase()
        if (value.includes("power") || value.includes("battery")
                || value.includes("charge") || value.includes("tlp")) {
            root.activeSection = "power"
            if (value.includes("battery care") || value.includes("charge care")
                    || value.includes("charge limit"))
                root.selectTlpCategory("battery-care")
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

    Component.onCompleted: {
        // Before TLP moved under System, iiPage=28 meant the standalone TLP
        // page. The registry rewrites that persisted page to System and leaves
        // this one-shot hint so the migration lands on Power, not Audio.
        if (SettingsPageRegistry.consumeLegacyTlpPowerRedirect())
            root.activeSection = "power"
    }

    // TLP now belongs to System → Power. It is appended to the inherited
    // ContentPage so there is one scroll surface and no nested Flickable.
    TlpPowerSettings {
        id: tlpPowerSettings
        Layout.fillWidth: true
        visible: root.activeSection === "power"
    }
}
