pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.waffle.looks
import qs.modules.waffle.settings

ColumnLayout {
    id: root

    required property var definition
    property bool compactProfileRows: false
    property bool singleSettingGroup: false

    readonly property string settingKey: String(root.definition?.key ?? "")
    readonly property string settingType: String(root.definition?.type ?? "text")
    readonly property string profile: String(root.definition?.profile ?? "")
    readonly property bool isProfileMapping: root.settingKey.startsWith("TLP_PROFILE_")
    readonly property bool compactProfileRow: root.isProfileMapping
        || (root.compactProfileRows && root.profile.length > 0)
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
    readonly property var editorNumberRange: root.computeNumberRange()
    readonly property string displayLabel: {
        const base = Translation.tr(TlpSettingsService.settingLabel(root.definition))
        const profileName = TlpSettingsService.profileLabel(root.profile)
        if (root.compactProfileRow)
            return Translation.tr(profileName)
        if (root.singleSettingGroup)
            return Translation.tr("Use custom value")
        return profileName.length > 0 ? base + " · " + Translation.tr(profileName) : base
    }

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
        if (next.length === 0 && root.settingKey.startsWith("PLATFORM_PROFILE_")) {
            root.unsetValue()
            return
        }
        root.setValue(next.join(" "))
    }

    function rowIcon(): string {
        switch (root.profile) {
        case "AC": return "power"
        case "BAT": return "battery-saver"
        case "SAV": return "battery-saver"
        default: return root.managed ? "settings-cog-multiple" : "settings"
        }
    }

    WSettingsSwitch {
        id: overrideSwitch
        property bool _ready: false
        label: root.displayLabel
        icon: root.rowIcon()
        description: ""
        checked: root.managed
        enabled: root.editable
        Component.onCompleted: _ready = true
        onCheckedChanged: {
            if (!_ready || checked === root.managed)
                return
            if (checked)
                root.setValue(root.defaultValue())
            else
                root.unsetValue()
        }
    }

    Loader {
        id: editorLoader
        Layout.fillWidth: true
        Layout.leftMargin: Looks.dp(28)
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

    WText {
        visible: root.notice.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: Looks.dp(28)
        Layout.rightMargin: Looks.dp(10)
        Layout.bottomMargin: Looks.dp(6)
        text: Translation.tr(root.notice)
        color: Looks.colors.danger
        font.pixelSize: Looks.font.pixelSize.small
        wrapMode: Text.WordWrap
    }

    Component {
        id: unsetEditor

        WSettingsTextField {
            label: Translation.tr("Value")
            placeholderText: Translation.tr("TLP default")
            text: ""
            enabled: false
        }
    }

    Component {
        id: numberEditor

        WSettingsSpinBox {
            property bool _ready: false
            label: Translation.tr("Value")
            description: Translation.tr("Allowed: %1–%2").arg(
                root.editorNumberRange.min).arg(root.editorNumberRange.max)
            suffix: String(root.definition?.unit ?? "")
            from: root.editorNumberRange.min
            to: root.editorNumberRange.max
            stepSize: Number(root.definition?.step ?? 1)
            value: {
                const parsed = Number.parseInt(root.currentValue, 10)
                return Number.isFinite(parsed) ? parsed : from
            }
            enabled: root.editable
            Component.onCompleted: _ready = true
            onValueChanged: {
                if (_ready && String(value) !== root.currentValue)
                    root.setValue(String(value))
            }
        }
    }

    Component {
        id: selectEditor

        WSettingsDropdown {
            label: Translation.tr("Value")
            currentValue: root.currentValue
            options: root.optionValues.map(value => ({
                value: String(value),
                displayName: Translation.tr(TlpSettingsService.displayValue(root.definition, value))
            }))
            enabled: root.editable
            onSelected: newValue => root.setValue(String(newValue))
        }
    }

    Component {
        id: textEditor

        WSettingsTextField {
            label: Translation.tr("Value")
            placeholderText: {
                if (root.managed && root.currentValue.length === 0)
                    return Translation.tr("Explicit empty value")
                const example = TlpSettingsService.exampleValue(root.definition)
                if (root.currentValue.trim().length === 0 && example.length > 0)
                    return Translation.tr("Example: %1").arg(example)
                return Translation.tr(String(root.definition?.placeholder
                    ?? "TLP configuration value"))
            }
            text: root.currentValue
            enabled: root.editable
            onTextEdited: newText => root.setValue(newText.trim())
        }
    }

    Component {
        id: listEditor

        Item {
            implicitHeight: tokenFlow.implicitHeight + Looks.dp(16)

            Flow {
                id: tokenFlow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                spacing: Looks.dp(6)

                Repeater {
                    model: root.optionValues

                    delegate: WButton {
                        required property var modelData
                        text: Translation.tr(TlpSettingsService.displayValue(root.definition, modelData))
                        checked: root.selectedTokens.indexOf(String(modelData)) >= 0
                        enabled: root.editable
                        font.pixelSize: Looks.font.pixelSize.small
                        horizontalPadding: Looks.dp(10)
                        verticalPadding: Looks.dp(5)
                        onClicked: root.toggleToken(String(modelData))
                    }
                }
            }
        }
    }

    Connections {
        target: TlpSettingsService

        function syncOverride(): void {
            overrideSwitch.checked = root.managed
        }

        function reloadEditor(): void {
            editorLoader.active = false
            Qt.callLater(() => editorLoader.active = true)
        }

        function onManagedValuesChanged(): void {
            Qt.callLater(syncOverride)
            reloadEditor()
        }
        function onEffectiveValuesChanged(): void { reloadEditor() }
        function onPendingValuesChanged(): void {
            Qt.callLater(syncOverride)
            if (!TlpSettingsService.hasPendingChanges)
                reloadEditor()
        }
    }
}
