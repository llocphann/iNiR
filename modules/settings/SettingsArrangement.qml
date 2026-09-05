pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common

QtObject {
    id: root

    readonly property int layoutSchemaVersion: 4
    readonly property int legacyTlpPageIndex: 28

    function snapshot(): var {
        return ({
            groups: SettingsPageRegistry.categories.map(c => ({
                label: c.label,
                pages: c.pages.slice()
            })),
            hidden: SettingsPageRegistry.hiddenPages.slice()
        })
    }

    function save(snapshot): void {
        Config.setNestedValue("settingsUi.categories", JSON.stringify({
            version: root.layoutSchemaVersion,
            groups: snapshot.groups,
            hidden: snapshot.hidden
        }))
    }

    function _defaultWithoutStandaloneTlp(): var {
        return ({
            groups: SettingsPageRegistry.defaultCategories.map(group => ({
                label: group.label,
                pages: group.pages.filter(index => index !== root.legacyTlpPageIndex)
            })),
            // Keep page 28 as a hidden compatibility target for old links and
            // static search entries. Canonical navigation is System → Power.
            hidden: [root.legacyTlpPageIndex]
        })
    }

    function migrateLegacyPageIndices(): void {
        const raw = Config.options?.settingsUi?.categories ?? ""

        // A fresh/default layout used to expose Battery/TLP as page 28. Write a
        // v4 arrangement once so that page becomes an internal compatibility
        // target and disappears from normal navigation.
        if (typeof raw !== "string" || raw.length === 0) {
            root.save(root._defaultWithoutStandaloneTlp())
            return
        }

        let saved
        try {
            saved = JSON.parse(raw)
        } catch (e) {
            return
        }

        const sourceVersion = Array.isArray(saved) ? 1 : Number(saved?.version ?? 2)
        if (!Array.isArray(saved) && sourceVersion >= root.layoutSchemaVersion)
            return

        const groups = Array.isArray(saved)
            ? saved
            : (Array.isArray(saved?.groups) ? saved.groups : null)
        if (!groups)
            return

        const hidden = Array.isArray(saved?.hidden) ? saved.hidden : []
        let hasLegacyTlpIndex = false
        let hasCurrentTlpIndex = false
        const inspectIndex = index => {
            if (index === 27)
                hasLegacyTlpIndex = true
            else if (index === root.legacyTlpPageIndex)
                hasCurrentTlpIndex = true
        }

        for (const group of groups) {
            if (!group || !Array.isArray(group.pages))
                continue
            group.pages.forEach(inspectIndex)
        }
        hidden.forEach(inspectIndex)

        // v1/v2 layouts from before Orbit used 27 for TLP. Preserve the old
        // disambiguation rule: when 28 is absent, that 27 is the retired TLP
        // page, not Orbit. Removing it lets Registry surface the newly added
        // Orbit page as missing, while TLP itself now lives under System.
        const dropPreOrbitTlp = sourceVersion < 3
            && hasLegacyTlpIndex && !hasCurrentTlpIndex
        const keepPage = index => index !== root.legacyTlpPageIndex
            && !(dropPreOrbitTlp && index === 27)

        const migratedGroups = groups.map(group => {
            if (!group || typeof group.label !== "string")
                return group
            return ({
                label: group.label,
                pages: (Array.isArray(group.pages) ? group.pages : []).filter(keepPage)
            })
        })
        const migratedHidden = hidden.filter(keepPage)
        if (!migratedHidden.includes(root.legacyTlpPageIndex))
            migratedHidden.push(root.legacyTlpPageIndex)

        root.save({ groups: migratedGroups, hidden: migratedHidden })
    }

    function removePage(snapshot, categoryIndex: int, pageIndex: int, pageIdx: int): int {
        if (categoryIndex === -1) {
            const hiddenIndex = snapshot.hidden.indexOf(pageIdx)
            if (hiddenIndex < 0)
                return -1
            snapshot.hidden.splice(hiddenIndex, 1)
            return pageIdx
        }

        const pages = snapshot.groups[categoryIndex]?.pages
        if (!pages)
            return -1
        let actual = pageIndex
        if (actual < 0 || actual >= pages.length || pages[actual] !== pageIdx)
            actual = pages.indexOf(pageIdx)
        if (actual < 0)
            return -1
        return pages.splice(actual, 1)[0]
    }

    function movePage(sourceCategory: int, sourceIndex: int, pageIdx: int,
                      targetCategory: int, targetIndex: int): bool {
        if (pageIdx === root.legacyTlpPageIndex)
            return false
        if (!SettingsPageRegistry.categories[targetCategory])
            return false

        const state = root.snapshot()
        const page = root.removePage(state, sourceCategory, sourceIndex, pageIdx)
        if (page < 0)
            return false

        const target = state.groups[targetCategory]?.pages
        if (!target)
            return false
        target.splice(Math.max(0, Math.min(targetIndex, target.length)), 0, page)
        root.save(state)
        return true
    }

    function hidePage(categoryIndex: int, pageIndex: int, pageIdx: int): bool {
        if (categoryIndex < 0)
            return false
        const state = root.snapshot()
        const page = root.removePage(state, categoryIndex, pageIndex, pageIdx)
        if (page < 0)
            return false
        if (!state.hidden.includes(page))
            state.hidden.push(page)
        root.save(state)
        return true
    }

    function bestRestoreCategory(pageIdx: int, groups): int {
        const defaults = SettingsPageRegistry.defaultCategories
        let peers = []
        for (let i = 0; i < defaults.length; i++) {
            if (defaults[i].pages.includes(pageIdx)) {
                peers = defaults[i].pages
                break
            }
        }

        let bestIndex = groups.length > 0 ? 0 : -1
        let bestScore = -1
        for (let i = 0; i < groups.length; i++) {
            let score = 0
            for (let j = 0; j < groups[i].pages.length; j++)
                if (peers.includes(groups[i].pages[j]))
                    score++
            if (score > bestScore) {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex
    }

    function restorePage(pageIdx: int): bool {
        // Page 28 is intentionally retired from navigation; its component is
        // kept only so old deep links/search metadata cannot break.
        if (pageIdx === root.legacyTlpPageIndex)
            return false

        const state = root.snapshot()
        const hiddenIndex = state.hidden.indexOf(pageIdx)
        if (hiddenIndex < 0)
            return false
        state.hidden.splice(hiddenIndex, 1)
        const target = root.bestRestoreCategory(pageIdx, state.groups)
        if (target < 0)
            state.groups.push({ label: Translation.tr("Essentials"), pages: [pageIdx] })
        else
            state.groups[target].pages.push(pageIdx)
        root.save(state)
        return true
    }

    function moveGroup(sourceIndex: int, insertIndex: int): bool {
        const state = root.snapshot()
        if (!state.groups[sourceIndex])
            return false
        const group = state.groups.splice(sourceIndex, 1)[0]
        let target = insertIndex
        if (insertIndex > sourceIndex)
            target--
        state.groups.splice(Math.max(0, Math.min(target, state.groups.length)), 0, group)
        root.save(state)
        return true
    }

    function renameCategory(index: int, label: string): bool {
        const trimmed = label.trim()
        if (trimmed.length === 0)
            return false
        const state = root.snapshot()
        if (!state.groups[index])
            return false
        state.groups[index].label = trimmed
        root.save(state)
        return true
    }

    function removeCategory(index: int): bool {
        const state = root.snapshot()
        if (state.groups.length <= 1 || !state.groups[index]
                || state.groups[index].pages.length > 0)
            return false
        state.groups.splice(index, 1)
        root.save(state)
        return true
    }

    function addCategory(): void {
        const state = root.snapshot()
        state.groups.push({ label: Translation.tr("New group"), pages: [] })
        root.save(state)
    }

    function reset(): void {
        // Reset to the canonical v4 layout immediately instead of briefly
        // exposing the retired standalone TLP page before migration reruns.
        root.save(root._defaultWithoutStandaloneTlp())
    }
}
