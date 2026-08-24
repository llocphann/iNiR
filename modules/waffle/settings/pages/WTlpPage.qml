pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.waffle.looks
import qs.modules.waffle.settings

WSettingsPage {
    id: root

    settingsPageIndex: 18
    pageTitle: Translation.tr("Battery")
    pageIcon: "battery-saver"
    pageDescription: Translation.tr("Charge care, power profiles, processor, devices, and the effective TLP configuration")

    property int selectedCategoryIndex: 0
    property string filterText: ""
    property bool _categoryReady: false
    property int _previousCategoryIndex: 0

    readonly property string profileGuidanceSource: "When overriding this group, set every shown profile together to avoid values spilling between TLP profiles."
    readonly property var selectedCategory: {
        const categories = TlpSettingsService._array(TlpSettingsService.navigationCategories)
        if (categories.length === 0)
            return null
        return categories[Math.max(0, Math.min(root.selectedCategoryIndex, categories.length - 1))]
    }
    readonly property var visibleGroups: TlpSettingsService.groupsForCategory(
        root.selectedCategory, root.filterText)
    readonly property bool profileGuidanceVisible: root.visibleGroups.some(group =>
        String(group?.description ?? "").includes(root.profileGuidanceSource))
    readonly property bool batteryCareSelected: String(root.selectedCategory?.id ?? "") === "battery-care"

    function conciseGroupDescription(group): string {
        const description = String(group?.description ?? "")
        if (description === root.profileGuidanceSource)
            return ""
        const suffix = " " + root.profileGuidanceSource
        return description.endsWith(suffix)
            ? description.slice(0, description.length - suffix.length)
            : description
    }

    function statusMessage(): string {
        if (!TlpSettingsService.schemaLoaded)
            return Translation.tr("The bundled TLP settings schema could not be loaded")
        if (!TlpSettingsService.available)
            return Translation.tr("TLP is not installed")
        if (!TlpSettingsService.supported)
            return TlpSettingsService.statusReason === "unsupported-tlp-version"
                ? Translation.tr("This TLP version is not supported yet")
                : Translation.tr("The installed TLP runtime is unavailable")
        if (!TlpSettingsService.configAvailable)
            return TlpSettingsService.statusReason === "managed-config-invalid"
                ? Translation.tr("The iNiR TLP override file is invalid; reset overrides to recover")
                : Translation.tr("TLP configuration could not be read")
        return TlpSettingsService.enabled
            ? Translation.tr("TLP %1 is active · %2 iNiR overrides").arg(
                TlpSettingsService.tlpVersion).arg(TlpSettingsService.managedCount)
            : Translation.tr("TLP %1 is disabled by configuration").arg(TlpSettingsService.tlpVersion)
    }

    function selectCategory(index: int): void {
        if (index === root.selectedCategoryIndex || TlpSettingsService.busy)
            return
        root.selectedCategoryIndex = index
    }

    onSelectedCategoryIndexChanged: {
        if (root._categoryReady
                && root._previousCategoryIndex !== root.selectedCategoryIndex
                && TlpSettingsService.hasPendingChanges)
            TlpSettingsService.applyOnLeave()
        root._previousCategoryIndex = root.selectedCategoryIndex
        root.filterText = ""
    }

    Component.onCompleted: {
        root._previousCategoryIndex = root.selectedCategoryIndex
        root._categoryReady = true
    }

    WSettingsInfoBar {
        severity: TlpSettingsService.configAvailable
            ? (TlpSettingsService.enabled
                ? WSettingsInfoBar.Severity.Success
                : WSettingsInfoBar.Severity.Warning)
            : WSettingsInfoBar.Severity.Error
        message: root.statusMessage()
    }

    WSettingsInfoBar {
        severity: WSettingsInfoBar.Severity.Error
        message: TlpSettingsService.lastError
    }

    WSettingsCard {
        title: Translation.tr("Apply changes")
        icon: "battery-saver"
        description: TlpSettingsService.hasPendingChanges
            ? Translation.tr("%1 staged change(s) · one Polkit authentication").arg(TlpSettingsService.pendingCount)
            : Translation.tr("Editors show TLP's current effective values; no shell reload is required")

        WSettingsButton {
            label: Translation.tr("Apply all staged changes")
            description: Translation.tr("Validate, write both iNiR drop-ins, run TLP once, and verify")
            buttonText: TlpSettingsService.busy ? Translation.tr("Applying…") : Translation.tr("Apply")
            accent: true
            enabled: TlpSettingsService.hasPendingChanges
                && TlpSettingsService.supported
                && TlpSettingsService.configAvailable
                && !TlpSettingsService.busy
            onButtonClicked: TlpSettingsService.apply()
        }

        WSettingsButton {
            label: Translation.tr("Discard staged changes")
            description: Translation.tr("Return every editor to the last effective configuration")
            buttonText: Translation.tr("Discard")
            enabled: TlpSettingsService.hasPendingChanges && !TlpSettingsService.busy
            onButtonClicked: TlpSettingsService.discard()
        }

        WSettingsButton {
            label: Translation.tr("Refresh effective configuration")
            description: Translation.tr("Read TLP settings and battery care state again")
            buttonText: Translation.tr("Refresh")
            enabled: !TlpSettingsService.busy
            onButtonClicked: {
                TlpSettingsService.refresh()
                TlpService.refresh()
            }
        }

        WSettingsButton {
            label: Translation.tr("Reset general iNiR overrides")
            description: TlpSettingsService.statusReason === "managed-config-invalid"
                ? Translation.tr("Delete the invalid iNiR-owned override file and keep battery charge care")
                : Translation.tr("Keep battery charge care and all non-iNiR TLP files")
            buttonText: Translation.tr("Reset")
            enabled: TlpSettingsService.canResetOverrides
            onButtonClicked: TlpSettingsService.reset()
        }
    }

    WSettingsCard {
        title: Translation.tr("Configuration categories")
        icon: "settings-cog-multiple"
        description: root.selectedCategory
            ? Translation.tr(String(root.selectedCategory.description ?? "")) : ""

        GridLayout {
            Layout.fillWidth: true
            columns: root.width >= Looks.dp(760) ? 3 : 2
            columnSpacing: Looks.dp(6)
            rowSpacing: Looks.dp(4)

            Repeater {
                model: TlpSettingsService.navigationCategories

                delegate: WSettingsNavItem {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.preferredWidth: 1
                    expanded: true
                    selected: root.selectedCategoryIndex === index
                    navIcon: String(modelData?.waffleIcon ?? "settings")
                    text: Translation.tr(TlpSettingsService.categoryLabel(modelData))
                    enabled: !TlpSettingsService.busy
                    onClicked: root.selectCategory(index)
                }
            }
        }

        WSettingsTextField {
            label: Translation.tr("Filter this category")
            placeholderText: Translation.tr("Name, parameter, or description")
            text: root.filterText
            onTextEdited: newText => root.filterText = newText
        }

        WText {
            visible: root.profileGuidanceVisible
            Layout.fillWidth: true
            Layout.leftMargin: Looks.dp(10)
            Layout.rightMargin: Looks.dp(10)
            text: Translation.tr("Profiled settings should be overridden together so values do not carry over between TLP profiles.")
            color: Looks.colors.subfg
            font.pixelSize: Looks.font.pixelSize.small
            wrapMode: Text.WordWrap
            lineHeight: 1.2
        }
    }

    WSettingsCard {
        visible: root.batteryCareSelected
        title: Translation.tr("Hardware-aware charge care")
        icon: "battery-saver"
        description: Translation.tr("TLP detects supported limits and applies them with the rest of this page")

        WBatteryChargeLimitRows {
            staged: true
        }
    }

    Repeater {
        model: root.visibleGroups

        delegate: WSettingsCard {
            id: groupCard
            required property var modelData
            title: Translation.tr(String(modelData?.title ?? ""))
            icon: String(root.selectedCategory?.waffleIcon ?? "settings")
            collapsible: true
            expanded: true

            WText {
                visible: root.conciseGroupDescription(groupCard.modelData).length > 0
                Layout.fillWidth: true
                Layout.leftMargin: Looks.dp(10)
                Layout.rightMargin: Looks.dp(10)
                Layout.topMargin: Looks.dp(4)
                Layout.bottomMargin: Looks.dp(8)
                text: Translation.tr(root.conciseGroupDescription(groupCard.modelData))
                color: Looks.colors.subfg
                font.pixelSize: Looks.font.pixelSize.small
                wrapMode: Text.WordWrap
                lineHeight: 1.25
            }

            Repeater {
                model: TlpSettingsService._array(groupCard.modelData?.settings)

                delegate: WTlpSettingRow {
                    required property var modelData
                    definition: modelData
                    compactProfileRows: TlpSettingsService.groupUsesCompactProfileRows(groupCard.modelData)
                    singleSettingGroup: TlpSettingsService._array(groupCard.modelData?.settings).length === 1
                }
            }
        }
    }

    WSettingsInfoBar {
        message: root.selectedCategory !== null && root.visibleGroups.length === 0
            ? Translation.tr("No matching settings. Try another search term or clear the filter.")
            : ""
    }
}
