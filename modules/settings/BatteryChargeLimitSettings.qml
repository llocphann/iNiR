pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ColumnLayout {
    id: root

    property bool showStatus: true
    property bool staged: false

    readonly property bool requestedEnabled: root.staged
        ? TlpSettingsService.chargeEnabled()
        : (Config.options?.battery?.chargeLimit?.enable ?? false)
    readonly property int requestedThreshold: root.staged
        ? TlpSettingsService.chargeThreshold()
        : Battery.effectiveChargeLimitThreshold

    Layout.fillWidth: true
    spacing: SettingsMaterialPreset.groupSpacing

    ConfigRow {
        enabled: Battery.chargeLimitSupported
            || Battery.chargeLimitManaged
            || root.requestedEnabled
        uniform: false
        Layout.fillWidth: false

        SettingsSwitch {
            buttonIcon: "battery_saver"
            text: Translation.tr("Charge limit")
            checked: root.requestedEnabled
            autoToggle: false
            onToggledByUser: checked => {
                if (root.staged)
                    TlpSettingsService.stageChargeEnabled(checked, root.requestedThreshold)
                else
                    Config.setNestedValue("battery.chargeLimit.enable", checked)
            }

            StyledToolTip {
                text: !Battery.chargeLimitAvailable
                    ? Translation.tr("TLP is not available")
                    : Battery.chargeLimitStatusReason === "unsupported-tlp-version"
                        ? Translation.tr("This TLP version is not supported yet")
                    : Battery.chargeLimitStatusReason === "tlp-disabled"
                        ? Translation.tr("TLP is disabled in its configuration")
                    : Battery.chargeLimitStatusReason === "tlp-config-unavailable"
                        ? Translation.tr("TLP configuration could not be read")
                    : !Battery.chargeLimitSupported
                        ? Translation.tr("Not supported on this device")
                    : Battery.chargeLimitDiscrete
                        ? Translation.tr("Choose a charge limit supported by this device (requires polkit)")
                    : Battery.chargeLimitAdjustable
                        ? Translation.tr("Stop charging at a specific percentage to extend battery lifespan (requires polkit)")
                        : Translation.tr("Use your device's built-in battery conservation mode (requires polkit)")
            }
        }

        ConfigSpinBox {
            property bool _ready: false
            visible: Battery.chargeLimitContinuous
            enabled: root.requestedEnabled && Battery.chargeLimitContinuous
            icon: "speed"
            text: Translation.tr("at")
            value: root.requestedThreshold
            from: Battery.chargeLimitMinimum
            to: Battery.chargeLimitMaximum
            stepSize: Battery.chargeLimitStepSize
            Component.onCompleted: _ready = true
            onValueChanged: {
                if (!_ready || value === root.requestedThreshold)
                    return
                if (root.staged)
                    TlpSettingsService.stageChargeThreshold(value)
                else
                    Config.setNestedValue("battery.chargeLimit.threshold", value)
            }

            StyledToolTip {
                text: Translation.tr("Maximum charge percentage")
            }
        }

        ConfigSelectionArray {
            visible: Battery.chargeLimitDiscrete
            enabled: root.requestedEnabled && Battery.chargeLimitDiscrete
            currentValue: root.requestedThreshold
            options: Battery.chargeLimitAllowedValues.map(value => ({
                displayName: String(value) + "%",
                value: value
            }))
            onSelected: newValue => {
                if (root.staged)
                    TlpSettingsService.stageChargeThreshold(Number(newValue))
                else
                    Config.setNestedValue("battery.chargeLimit.threshold", newValue)
            }
        }
    }

    StyledText {
        visible: root.showStatus && Battery.chargeLimitSupported
        Layout.leftMargin: SettingsMaterialPreset.groupPadding
        text: !Battery.chargeLimitStateKnown
            ? Translation.tr("Charge limit state unavailable")
            : Battery.chargeLimitActive
                ? (Battery.chargeLimitAdjustable && Battery.currentChargeLimit > 0 && Battery.currentChargeLimit < 100
                    ? Translation.tr("Current limit: %1%").arg(Battery.currentChargeLimit)
                    : Translation.tr("Battery conservation mode active"))
                : Translation.tr("No charge limit active")
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colSubtext
    }
}
