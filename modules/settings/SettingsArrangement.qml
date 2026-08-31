pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common

QtObject {
    id: root

    readonly property int layoutSchemaVersion: 3

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

    function migrateLegacyPageIndices(): void {
        const raw = Config.options?.settingsUi?.categories ?? ""
        if (typeof raw !== "string" || raw.length === 0)
            return

        let saved
        try {
            saved = JSON.parse(raw)
        } catch (e) {
            return
        }

        if (!Array.isArray(saved)
                && Number(saved?.version ?? 0) >= root.layoutSchemaVersion)
            return

        const groups = Array.isArray(saved)
            ? saved
            : (Array.isArray(saved?.groups) ? saved.groups : null)
        if (!groups)
            return

        const hidden = Array.isArray(saved?.hidden) ? saved.hidden : []
        let hasLegacyTlpIndex = false
        let hasCurrentTlpIndex = false

        function inspectIndex(index): void {
            if (index === 27)
                hasLegacyTlpIndex = true
            else if (index === 28)
                hasCurrentTlpIndex = true
        }

        for (const group of groups) {
            if (!group || !Array.isArray(group.pages))
                continue
            group.pages.forEach(inspectIndex)
        }
        hidden.forEach(inspectIndex)

        const shouldRemapTlp = hasLegacyTlpIndex && !hasCurrentTlpIndex
        const migratedGroups = groups.map(group => {
            if (!group || typeof group.label !== "string")
                return group
            return ({
                label: group.label,
                pages: (Array.isArray(group.pages) ? group.pages : [])
                    .map(index => shouldRemapTlp && index === 27 ? 28 : index)
            })
        })
        const migratedHidden = hidden
            .map(index => shouldRemapTlp && index === 27 ? 28 : index)

        // Pre-Orbit fork layouts used index 27 for Battery/TLP. Orbit now owns
        // 27 and Battery/TLP moved to 28, so preserve the user's old placement
        // or hidden state. A newly added Orbit page is intentionally left
        // missing; SettingsPageRegistry will surface it in the trailing More
        // group, matching the existing behavior for newly introduced pages.
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
        Config.setNestedValue("settingsUi.categories", "")
    }
}
