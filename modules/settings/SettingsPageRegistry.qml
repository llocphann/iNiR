pragma Singleton
import QtQuick
import qs.modules.common

/**
 * Public Settings registry facade.
 *
 * The historical registry is kept byte-for-byte in SettingsPageRegistryData.
 * Battery/TLP used to be its final page (28). TLP now belongs to System →
 * Power, so this facade removes that retired page from every navigation model
 * and redirects its static search entries to System without shifting any of
 * the existing 0…27 page indices.
 */
Singleton {
    id: root

    readonly property int retiredTlpPageIndex: 28
    readonly property int systemPageIndex: 1

    readonly property var pages: SettingsPageRegistryData.pages.filter(
        (page, index) => index !== root.retiredTlpPageIndex)

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

    function iconForPage(idx) {
        return (idx >= 0 && idx < root.pages.length)
            ? (root.pages[idx].icon || "settings") : "settings"
    }

    function searchIndex(): var {
        return SettingsPageRegistryData.searchIndex().map(entry => {
            if (entry.pageIndex !== root.retiredTlpPageIndex)
                return entry

            const redirected = Object.assign({}, entry)
            redirected.pageIndex = root.systemPageIndex
            redirected.pageName = root.pages[root.systemPageIndex].name
            return redirected
        })
    }
}
