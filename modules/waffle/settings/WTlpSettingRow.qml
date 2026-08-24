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

    function defaultValue(): string {
        if (root.currentValue.length > 0)
            return root.currentValue
        if (root.inheritedValue.length > 0)
            return root.inheritedValue
        const example = TlpSettingsService.exampleValue(root.definition)
        if (example.length > 0)
            return example
        if (root.settingType === "number")
            return String(root.definition?.min ?? 0)
        return root.optionValues.length > 0 ? String(root.optionValues[0]) : ""
    }

    function setValue(value): void {
        TlpSettingsService.stageSet(root.settingKey, String(value ?? ""))
    }

    function toggleToken(token: string): void {
        const next = root.selectedTokens.slice()
        const index = next.indexOf(token)
        if (index >= 0)
            next.splice(index, 1)
        else
            next.push(token)
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
                TlpSettingsService.stageUnset(root.settingKey)
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
                root.definition?.min ?? 0).arg(root.definition?.max ?? 100)
            suffix: String(root.definition?.unit ?? "")
            from: Number(root.definition?.min ?? 0)
            to: Number(root.definition?.max ?? 100)
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
