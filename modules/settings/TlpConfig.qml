pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: root

    settingsPageIndex: 27
    settingsPageName: Translation.tr("Battery")

    property int selectedCategoryIndex: 0
    property string filterText: ""

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

    function statusDescription(): string {
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

    onSelectedCategoryIndexChanged: root.filterText = ""

    SettingsCardSection {
        expanded: true
        collapsible: false
        icon: "battery_saver"
        title: Translation.tr("Battery and TLP power management")

        SettingsGroup {
            RowLayout {
                Layout.fillWidth: true
                spacing: SettingsMaterialPreset.groupPadding

                MaterialSymbol {
                    text: TlpSettingsService.configAvailable
                        ? (TlpSettingsService.enabled ? "check_circle" : "pause_circle")
                        : "warning"
                    iconSize: Appearance.font.pixelSize.huge
                    color: TlpSettingsService.configAvailable
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colError
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: SettingsMaterialPreset.groupSpacing

                    StyledText {
                        Layout.fillWidth: true
                        text: root.statusDescription()
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        visible: TlpSettingsService.configAvailable
                            || TlpSettingsService.managedConfigPresent
                        Layout.fillWidth: true
                        text: Translation.tr("Managed settings: %1").arg(TlpSettingsService.configFile)
                        color: Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.family: Appearance.font.family.monospace
                        elide: Text.ElideMiddle
                    }
                }

                DialogButton {
                    buttonText: Translation.tr("Refresh status")
                    enabled: !TlpSettingsService.busy
                    onClicked: {
                        TlpSettingsService.refresh()
                        TlpService.refresh()
                    }
                }
            }

            StyledText {
                visible: TlpSettingsService.lastError.length > 0
                Layout.fillWidth: true
                text: TlpSettingsService.lastError
                color: Appearance.colors.colError
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            SettingsDivider {}

            RowLayout {
                Layout.fillWidth: true
                spacing: SettingsMaterialPreset.groupSpacing

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: SettingsMaterialPreset.groupSpacing

                    StyledText {
                        Layout.fillWidth: true
                        text: TlpSettingsService.hasPendingChanges
                            ? Translation.tr("%1 staged change(s)").arg(TlpSettingsService.pendingCount)
                            : Translation.tr("Values shown below come from TLP's effective configuration")
                        color: TlpSettingsService.hasPendingChanges
                            ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        font.weight: TlpSettingsService.hasPendingChanges ? Font.Medium : Font.Normal
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Apply validates every change and authenticates only once. No shell reload is required.")
                        color: Appearance.colors.colSubtext
                        wrapMode: Text.WordWrap
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }
                }

                DialogButton {
                    buttonText: Translation.tr("Discard")
                    enabled: TlpSettingsService.hasPendingChanges && !TlpSettingsService.busy
                    onClicked: TlpSettingsService.discard()
                }

                DialogButton {
                    buttonText: TlpSettingsService.busy
                        ? Translation.tr("Applying…")
                        : Translation.tr("Apply")
                    enabled: TlpSettingsService.hasPendingChanges
                        && TlpSettingsService.supported
                        && TlpSettingsService.configAvailable
                        && !TlpSettingsService.busy
                    colBackground: Appearance.colors.colPrimary
                    colBackgroundHover: Appearance.colors.colPrimaryHover
                    colRipple: Appearance.colors.colPrimaryActive
                    colText: Appearance.colors.colOnPrimary
                    onClicked: TlpSettingsService.apply()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: SettingsMaterialPreset.groupSpacing

                StyledText {
                    Layout.fillWidth: true
                    text: TlpSettingsService.statusReason === "managed-config-invalid"
                        ? Translation.tr("Reset deletes the invalid iNiR-owned TLP override file so TLP can fall back to its remaining configuration.")
                        : Translation.tr("Reset removes only the general iNiR TLP override file; battery charge care stays separate.")
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    wrapMode: Text.WordWrap
                }

                DialogButton {
                    buttonText: Translation.tr("Reset overrides")
                    enabled: TlpSettingsService.canResetOverrides
                    onClicked: TlpSettingsService.reset()
                }
            }
        }
    }

    SettingsCardSection {
        expanded: true
        collapsible: false
        icon: "category"
        title: Translation.tr("Configuration categories")

        SettingsGroup {
            GridLayout {
                Layout.fillWidth: true
                columns: root.width >= 760 ? 4 : (root.width >= 540 ? 3 : 2)
                columnSpacing: SettingsMaterialPreset.groupSpacing
                rowSpacing: SettingsMaterialPreset.groupSpacing

                Repeater {
                    model: TlpSettingsService.navigationCategories

                    delegate: SelectionGroupButton {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: 1
                        leftmost: true
                        rightmost: true
                        buttonIcon: String(modelData?.icon ?? "tune")
                        buttonText: Translation.tr(TlpSettingsService.categoryLabel(modelData))
                        toggled: root.selectedCategoryIndex === index
                        enabled: !TlpSettingsService.busy
                        onClicked: root.selectCategory(index)
                    }
                }
            }

            SettingsDivider {}

            MaterialTextField {
                Layout.fillWidth: true
                placeholderText: Translation.tr("Filter by name, parameter, or description")
                text: root.filterText
                onTextEdited: root.filterText = text
            }

            StyledText {
                visible: root.selectedCategory !== null
                Layout.fillWidth: true
                text: root.selectedCategory
                    ? Translation.tr(String(root.selectedCategory.description ?? "")) : ""
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            StyledText {
                visible: root.profileGuidanceVisible
                Layout.fillWidth: true
                text: Translation.tr("Profiled settings should be overridden together so values do not carry over between TLP profiles.")
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    SettingsCardSection {
        visible: root.batteryCareSelected
        expanded: true
        collapsible: false
        icon: "battery_saver"
        title: Translation.tr("Hardware-aware charge care")

        SettingsGroup {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("TLP detects supported charge limits. Apply saves them with the other Battery changes.")
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            BatteryChargeLimitSettings {
                staged: true
            }
        }
    }

    Repeater {
        model: root.visibleGroups

        delegate: SettingsCardSection {
            id: groupCard
            required property var modelData
            expanded: true
            collapsible: true
            icon: String(root.selectedCategory?.icon ?? "tune")
            title: Translation.tr(String(modelData?.title ?? ""))

            SettingsGroup {
                StyledText {
                    visible: root.conciseGroupDescription(groupCard.modelData).length > 0
                    Layout.fillWidth: true
                    text: Translation.tr(root.conciseGroupDescription(groupCard.modelData))
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.WordWrap
                    font.pixelSize: Appearance.font.pixelSize.smallest
                }

                SettingsDivider {
                    visible: root.conciseGroupDescription(groupCard.modelData).length > 0
                }

                Repeater {
                    model: TlpSettingsService._array(groupCard.modelData?.settings)

                    delegate: TlpSettingRow {
                        required property var modelData
                        definition: modelData
                        groupDescription: root.conciseGroupDescription(groupCard.modelData)
                        compactProfileRows: TlpSettingsService.groupUsesCompactProfileRows(groupCard.modelData)
                        singleSettingGroup: TlpSettingsService._array(groupCard.modelData?.settings).length === 1
                    }
                }
            }
        }
    }

    SettingsCardSection {
        visible: root.selectedCategory !== null && root.visibleGroups.length === 0
        expanded: true
        collapsible: false
        icon: "search_off"
        title: Translation.tr("No matching settings")

        SettingsGroup {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Try another search term or clear the category filter.")
                color: Appearance.colors.colSubtext
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
