pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ColumnLayout {
    id: root

    required property var definition
    property string groupDescription: ""
    property bool compactProfileRows: false
    property bool singleSettingGroup: false

    readonly property string settingKey: String(root.definition?.key ?? "")
    readonly property string settingType: String(root.definition?.type ?? "text")
    readonly property string profile: String(root.definition?.profile ?? "")
    readonly property bool isProfileMapping: root.settingKey.startsWith("TLP_PROFILE_")
    readonly property bool compactProfileRow: root.isProfileMapping
        || (root.compactProfileRows && root.profile.length > 0)
    readonly property string label: TlpSettingsService.settingLabel(root.definition)
    readonly property string displayLabel: root.compactProfileRow
        ? Translation.tr(TlpSettingsService.profileLabel(root.profile))
        : root.singleSettingGroup
            ? Translation.tr("Use custom value")
            : Translation.tr(root.label)
    readonly property bool managed: TlpSettingsService.isManaged(root.settingKey)
    readonly property bool pending: Object.prototype.hasOwnProperty.call(
        TlpSettingsService.pendingValues, root.settingKey)
    readonly property string currentValue: TlpSettingsService.value(root.settingKey)
    readonly property string inheritedValue: TlpSettingsService.effectiveValue(root.settingKey)
    readonly property bool editable: TlpSettingsService.supported
        && TlpSettingsService.configAvailable
        && !TlpSettingsService.busy
    readonly property bool hasVisibleValue: root.managed || root.currentValue.length > 0
    readonly property string notice: root.managed || root.pending
        ? TlpSettingsService.settingNotice(root.definition) : ""
    readonly property var selectedTokens: root.currentValue.trim()
        ? root.currentValue.trim().split(/\s+/)
        : []
    readonly property var optionValues: TlpSettingsService.optionValues(root.definition)
    readonly property var optionLabels: root.optionValues.map(value =>
        Translation.tr(TlpSettingsService.displayValue(root.definition, value)))
    readonly property var editorNumberRange: root.computeNumberRange()
    readonly property real editorHeight: 38 * Appearance.fontSizeScale
    readonly property real editorWidth: root.settingType === "list" ? 310 : 240

    Layout.fillWidth: true
    spacing: 0

    function gpuFrequencyMatch(key): var {
        return String(key ?? "").match(/^INTEL_GPU_(MIN|MAX|BOOST)_FREQ_ON_(AC|BAT|SAV)$/)
    }

    function gpuFrequencyGroupKeys(): var {
        const match = root.gpuFrequencyMatch(root.settingKey)
        if (!match)
            return []
        const driver = String(TlpRuntimeCapabilities.intelGpuDriver ?? "")
        const suffix = match[2]
        if (driver === "xe") {
            if (match[1] === "BOOST")
                return []
            return [
                "INTEL_GPU_MIN_FREQ_ON_" + suffix,
                "INTEL_GPU_MAX_FREQ_ON_" + suffix
            ]
        }
        if (driver === "i915" || driver === "mixed") {
            return [
                "INTEL_GPU_MIN_FREQ_ON_" + suffix,
                "INTEL_GPU_MAX_FREQ_ON_" + suffix,
                "INTEL_GPU_BOOST_FREQ_ON_" + suffix
            ]
        }
        return []
    }

    function runtimeRangeFor(key): var {
        void TlpRuntimeCapabilities.numberRanges
        const ranges = TlpRuntimeCapabilities.numberRanges
        if (!Object.prototype.hasOwnProperty.call(ranges, key))
            return null
        const range = ranges[key]
        const minimum = Number(range?.min)
        const maximum = Number(range?.max)
        if (!Number.isFinite(minimum) || !Number.isFinite(maximum) || minimum > maximum)
            return null
        return ({ min: minimum, max: maximum })
    }

    function runtimeDefaultFor(key): string {
        void TlpRuntimeCapabilities.numberDefaults
        const defaults = TlpRuntimeCapabilities.numberDefaults
        if (!Object.prototype.hasOwnProperty.call(defaults, key))
            return ""
        const value = Number(defaults[key])
        return Number.isFinite(value) ? String(Math.round(value)) : ""
    }

    function safePeerNumber(key) {
        void TlpSettingsService.pendingValues
        void TlpSettingsService.managedValues
        void TlpSettingsService.effectiveValues
        const value = Number.parseInt(TlpSettingsService.value(key), 10)
        if (!Number.isFinite(value))
            return Number.NaN
        const range = root.runtimeRangeFor(key)
        if (range !== null && (value < range.min || value > range.max))
            return Number.NaN
        return value
    }

    function computeNumberRange(): var {
        const runtimeRange = root.runtimeRangeFor(root.settingKey)
        const schemaMin = Number(root.definition?.min ?? 0)
        const schemaMax = Number(root.definition?.max ?? 100)
        const baseMin = runtimeRange !== null ? runtimeRange.min : schemaMin
        const baseMax = runtimeRange !== null ? runtimeRange.max : schemaMax
        let minimum = baseMin
        let maximum = baseMax

        const match = root.gpuFrequencyMatch(root.settingKey)
        if (match) {
            const kind = match[1]
            const suffix = match[2]
            const minKey = "INTEL_GPU_MIN_FREQ_ON_" + suffix
            const maxKey = "INTEL_GPU_MAX_FREQ_ON_" + suffix
            const boostKey = "INTEL_GPU_BOOST_FREQ_ON_" + suffix
            const minValue = root.safePeerNumber(minKey)
            const maxValue = root.safePeerNumber(maxKey)
            const boostValue = root.safePeerNumber(boostKey)
            const hasBoost = String(TlpRuntimeCapabilities.intelGpuDriver ?? "") !== "xe"

            if (kind === "MIN") {
                if (Number.isFinite(maxValue))
                    maximum = Math.min(maximum, maxValue)
                if (hasBoost && Number.isFinite(boostValue))
                    maximum = Math.min(maximum, boostValue)
            } else if (kind === "MAX") {
                if (Number.isFinite(minValue))
                    minimum = Math.max(minimum, minValue)
                if (hasBoost && Number.isFinite(boostValue))
                    maximum = Math.min(maximum, boostValue)
            } else if (kind === "BOOST") {
                if (Number.isFinite(maxValue))
                    minimum = Math.max(minimum, maxValue)
            }
        }

        // An old/stale override can violate today's firmware range. Never turn
        // that into an impossible spinbox; fall back to the hardware interval so
        // the user can repair or remove it instead of being locked out.
        if (minimum > maximum) {
            minimum = baseMin
            maximum = baseMax
        }
        return ({ min: minimum, max: maximum })
    }

    function safeGpuPeerValue(key): string {
        const current = root.safePeerNumber(key)
        if (Number.isFinite(current))
            return String(current)
        return root.runtimeDefaultFor(key)
    }

    function defaultValue(): string {
        if (root.currentValue.length > 0)
            return root.currentValue
        if (root.inheritedValue.length > 0)
            return root.inheritedValue
        const runtimeDefault = root.runtimeDefaultFor(root.settingKey)
        if (runtimeDefault.length > 0)
            return runtimeDefault
        const example = TlpSettingsService.exampleValue(root.definition)
        if (example.length > 0)
            return example
        if (root.settingType === "number")
            return String(root.editorNumberRange.min)
        return root.optionValues.length > 0 ? String(root.optionValues[0]) : ""
    }

    function setValue(value): void {
        const normalized = String(value ?? "")
        const groupKeys = root.gpuFrequencyGroupKeys()
        if (groupKeys.length > 0) {
            // TLP validates Intel GPU frequencies as a complete pair (xe) or
            // trio (i915). Stage the whole profile atomically so enabling one
            // row can never create a configuration which TLP will reject.
            for (const key of groupKeys) {
                const nextValue = key === root.settingKey
                    ? normalized : root.safeGpuPeerValue(key)
                if (nextValue.length > 0)
                    TlpSettingsService.stageSet(key, nextValue)
            }
            return
        }
        TlpSettingsService.stageSet(root.settingKey, normalized)
    }

    function unsetValue(): void {
        const groupKeys = root.gpuFrequencyGroupKeys()
        if (groupKeys.length > 0) {
            for (const key of groupKeys)
                TlpSettingsService.stageUnset(key)
            return
        }
        TlpSettingsService.stageUnset(root.settingKey)
    }

    function toggleToken(token: string): void {
        const next = root.selectedTokens.slice()
        const index = next.indexOf(token)
        if (index >= 0)
            next.splice(index, 1)
        else
            next.push(token)

        // TLP 1.11 platform profiles require a non-empty ordered fallback
        // list. Removing the last chip means "inherit TLP" rather than staging
        // an empty value which the privileged helper must reject.
        if (next.length === 0 && root.settingKey.startsWith("PLATFORM_PROFILE_")) {
            root.unsetValue()
            return
        }
        root.setValue(next.join(" "))
    }

    function profileIcon(): string {
        switch (root.profile) {
        case "AC": return "bolt"
        case "BAT": return "battery_5_bar"
        case "SAV": return "energy_savings_leaf"
        case "DEFAULT": return "home"
        default: return ""
        }
    }

    function stateText(): string {
        if (root.pending)
            return root.managed
                ? Translation.tr("Staged for Apply")
                : Translation.tr("Will inherit after Apply")
        if (root.managed)
            return Translation.tr("Overridden by iNiR")
        if (root.inheritedValue.length > 0)
            return Translation.tr("Inherited: %1").arg(root.inheritedValue)
        return Translation.tr("TLP default")
    }

    function wrapToolTip(text: string): string {
        const words = text.trim().split(/\s+/)
        const lines = []
        let line = ""
        for (const word of words) {
            const candidate = line.length > 0 ? line + " " + word : word
            if (candidate.length > 64 && line.length > 0) {
                lines.push(line)
                line = word
            } else {
                line = candidate
            }
        }
        if (line.length > 0)
            lines.push(line)
        return lines.join("\n")
    }

    function toggleToolTip(): string {
        const action = root.managed
            ? Translation.tr("Disable this override to inherit TLP's value after Apply.")
            : Translation.tr("Enable an iNiR override for this setting.")
        const parameter = Translation.tr("Parameter: %1").arg(root.settingKey)
        const state = Translation.tr("State: %1").arg(root.stateText())
        const note = root.wrapToolTip(Translation.tr(root.groupDescription))
        const warning = root.wrapToolTip(Translation.tr(root.notice))
        let result = action + "\n" + parameter + "\n" + state
        if (note.length > 0)
            result += "\n" + note
        if (warning.length > 0)
            result += "\n" + warning
        return result
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: SettingsMaterialPreset.groupSpacing
        Layout.rightMargin: SettingsMaterialPreset.groupSpacing
        Layout.topMargin: SettingsMaterialPreset.groupSpacing
        Layout.bottomMargin: root.notice.length > 0 ? 0 : SettingsMaterialPreset.groupSpacing
        spacing: SettingsMaterialPreset.groupPadding

        StyledSwitch {
            Layout.alignment: Qt.AlignVCenter
            hoverEnabled: true
            checked: root.managed
            enabled: root.editable
            onClicked: {
                if (checked)
                    root.setValue(root.defaultValue())
                else
                    root.unsetValue()
            }

            StyledToolTip {
                text: root.toggleToolTip()
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 150
            Layout.alignment: Qt.AlignVCenter
            spacing: 0

            StyledText {
                Layout.fillWidth: true
                text: root.displayLabel
                color: root.pending
                    ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
        }

        Rectangle {
            id: profileBadge
            visible: root.profile.length > 0 && !root.isProfileMapping && !root.compactProfileRows
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: profileRow.implicitWidth + SettingsMaterialPreset.groupPadding
            implicitHeight: Math.round(24 * Appearance.fontSizeScale)
            radius: Appearance.rounding.full
            color: Appearance.colors.colSecondaryContainer

            RowLayout {
                id: profileRow
                anchors.centerIn: parent
                spacing: SettingsMaterialPreset.groupSpacing

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.profileIcon()
                    iconSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSecondaryContainer
                }

                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    text: Translation.tr(TlpSettingsService.profileLabel(root.profile))
                    color: Appearance.colors.colOnSecondaryContainer
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }
            }
        }

        Loader {
            id: editorLoader
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: root.editorWidth
            Layout.maximumWidth: root.editorWidth
            opacity: root.managed ? 1 : 0.72
            enabled: root.editable
            active: true
            sourceComponent: !root.hasVisibleValue
                ? unsetEditor
                : root.settingType === "number"
                    ? numberEditor
                    : root.settingType === "select"
                        ? selectEditor
                        : root.settingType === "list"
                            ? listEditor
                            : textEditor
        }
    }

    StyledText {
        visible: root.notice.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: SettingsMaterialPreset.groupSpacing
        Layout.rightMargin: SettingsMaterialPreset.groupSpacing
        Layout.bottomMargin: SettingsMaterialPreset.groupSpacing
        text: Translation.tr(root.notice)
        color: Appearance.colors.colError
        font.pixelSize: Appearance.font.pixelSize.smaller
        wrapMode: Text.WordWrap
    }

    Component {
        id: unsetEditor

        Rectangle {
            width: root.editorWidth
            implicitHeight: root.editorHeight
            radius: Appearance.rounding.small
            color: Appearance.colors.colLayer2

            StyledText {
                anchors.fill: parent
                anchors.leftMargin: SettingsMaterialPreset.groupPadding
                anchors.rightMargin: SettingsMaterialPreset.groupPadding
                text: Translation.tr("TLP default")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    Component {
        id: numberEditor

        RowLayout {
            spacing: SettingsMaterialPreset.groupSpacing

            StyledSpinBox {
                Layout.fillWidth: true
                baseHeight: root.editorHeight
                from: root.editorNumberRange.min
                to: root.editorNumberRange.max
                stepSize: Number(root.definition?.step ?? 1)
                value: {
                    const parsed = Number.parseInt(root.currentValue, 10)
                    return Number.isFinite(parsed) ? parsed : from
                }
                enabled: root.editable
                onValueModified: root.setValue(String(value))
            }

            StyledText {
                visible: String(root.definition?.unit ?? "").length > 0
                text: String(root.definition?.unit ?? "")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    Component {
        id: selectEditor

        StyledComboBox {
            width: root.editorWidth
            baseHeight: root.editorHeight
            model: root.optionLabels
            currentIndex: root.optionValues.indexOf(root.currentValue)
            enabled: root.editable
            onActivated: index => {
                if (index >= 0 && index < root.optionValues.length)
                    root.setValue(String(root.optionValues[index]))
            }
        }
    }

    Component {
        id: listEditor

        Item {
            width: root.editorWidth
            implicitHeight: Math.max(root.editorHeight, optionFlow.implicitHeight)

            Flow {
                id: optionFlow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                spacing: SettingsMaterialPreset.groupSpacing

                Repeater {
                    model: root.optionValues

                    delegate: FilterChip {
                        required property var modelData
                        text: Translation.tr(TlpSettingsService.displayValue(root.definition, modelData))
                        monospace: false
                        selected: root.selectedTokens.indexOf(String(modelData)) >= 0
                        enabled: root.editable
                        onClicked: root.toggleToken(String(modelData))
                    }
                }
            }
        }
    }

    Component {
        id: textEditor

        ToolbarTextField {
            width: root.editorWidth
            implicitHeight: root.editorHeight
            text: root.currentValue
            placeholderText: {
                if (root.managed && root.currentValue.length === 0)
                    return Translation.tr("Explicit empty value")
                const example = TlpSettingsService.exampleValue(root.definition)
                if (root.currentValue.trim().length === 0 && example.length > 0)
                    return Translation.tr("Example: %1").arg(example)
                return Translation.tr(String(root.definition?.placeholder
                    ?? "TLP configuration value"))
            }
            enabled: root.editable
            font.family: Appearance.font.family.monospace
            onTextEdited: root.setValue(text.trim())
        }
    }

    SettingsDivider {}

    Connections {
        target: TlpSettingsService

        function reloadEditor(): void {
            editorLoader.active = false
            Qt.callLater(() => editorLoader.active = true)
        }

        function onManagedValuesChanged(): void { reloadEditor() }
        function onEffectiveValuesChanged(): void { reloadEditor() }
        function onPendingValuesChanged(): void {
            if (!TlpSettingsService.hasPendingChanges)
                reloadEditor()
        }
    }
}
