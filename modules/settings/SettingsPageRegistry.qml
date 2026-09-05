pragma Singleton
import QtQuick
import qs.services
import qs.modules.common

/**
 * Public Settings registry facade.
 *
 * The historical registry is kept byte-for-byte in SettingsPageRegistryData.
 * Battery/TLP used to be its final page (28). TLP now belongs to System →
 * Power. Page 28 remains only as an internal compatibility alias so a legacy
 * persisted/current-page value can never clamp to Orbit before migration runs;
 * sidebar/category/search navigation still exposes only the canonical pages.
 */
Singleton {
    id: root

    readonly property int retiredTlpPageIndex: 28
    readonly property int systemPageIndex: 1
    property bool _legacyTlpPowerRedirectPending: false

    readonly property var pages: SettingsPageRegistryData.pages.map((page, index) => {
        if (index !== root.retiredTlpPageIndex)
            return page
        const systemPage = SettingsPageRegistryData.pages[root.systemPageIndex]
        // Preserve the historical `tlp` key/component for old direct links,
        // while presenting it as System if a legacy host opens index 28 before
        // Persistent migration gets a chance to rewrite the stored index.
        return Object.assign({}, page, {
            name: systemPage.name,
            icon: systemPage.icon,
            desc: systemPage.desc,
            essential: systemPage.essential
        })
    })

    readonly property var defaultCategories: SettingsPageRegistryData.defaultCategories.map(category => ({
        label: category.label,
        pages: category.pages.filter(index => index !== root.retiredTlpPageIndex)
    }))

    readonly property var categories: SettingsPageRegistryData.categories.map(category => ({
        label: category.label,
        pages: category.pages.filter(index => index !== root.retiredTlpPageIndex)
    }))

    readonly property var hiddenPages: SettingsPageRegistryData.hiddenPages.filter(
        index => index !== root.retiredTlpPageIndex)

    // Compatibility shape for code that introspects the sanitized arrangement.
    readonly property var _arrangement: ({ groups: root.categories, hidden: root.hiddenPages })

    function _migrateLegacyPersistentPage(): void {
        if (!Persistent.ready || !Persistent.states?.settings)
            return
        if (Number(Persistent.states.settings.iiPage ?? -1) !== root.retiredTlpPageIndex)
            return

        Persistent.states.settings.iiPage = root.systemPageIndex
        root._legacyTlpPowerRedirectPending = true
    }

    function consumeLegacyTlpPowerRedirect(): bool {
        if (!root._legacyTlpPowerRedirectPending)
            return false
        root._legacyTlpPowerRedirectPending = false
        return true
    }

    function iconForPage(idx) {
        return (idx >= 0 && idx < root.pages.length)
            ? (root.pages[idx].icon || "settings") : "settings"
    }

    function searchIndex(): var {
        return SettingsPageRegistryData.searchIndex().map(entry => {
            if (entry.pageIndex !== root.retiredTlpPageIndex)
                return entry

            const redirected = Object.assign({}, entry)
            const keywords = Array.isArray(entry.keywords) ? entry.keywords : []
            const chargeCareEntry = keywords.includes("threshold")
                || keywords.includes("conservation")

            redirected.pageIndex = root.systemPageIndex
            redirected.pageName = root.pages[root.systemPageIndex].name
            // Search navigation uses section to activate task tabs and label to
            // resolve the actual SettingsCardSection. Charge Care also needs
            // its TLP category selected before the card becomes visible.
            redirected.section = chargeCareEntry
                ? Translation.tr("Power") + " · " + Translation.tr("Battery Care")
                : Translation.tr("Power")
            redirected.label = chargeCareEntry
                ? Translation.tr("Hardware-aware charge care")
                : Translation.tr("Battery and TLP power management")
            redirected.keywords = keywords.concat(["system", "settings", "power"])
            return redirected
        })
    }

    Component.onCompleted: root._migrateLegacyPersistentPage()

    Connections {
        target: Persistent
        function onReadyChanged(): void {
            if (Persistent.ready)
                root._migrateLegacyPersistentPage()
        }
    }
}
