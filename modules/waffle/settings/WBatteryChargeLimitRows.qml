pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common

ColumnLayout {
    id: root

    property bool staged: false

    readonly property bool requestedEnabled: root.staged
        ? TlpSettingsService.chargeEnabled()
        : (Config.options?.battery?.chargeLimit?.enable ?? false)
    readonly property int requestedThreshold: root.staged
        ? TlpSettingsService.chargeThreshold()
        : Battery.effectiveChargeLimitThreshold

    Layout.fillWidth: true
    spacing: 0

    WSettingsSwitch {
        property bool _ready: false
        label: Translation.tr("Charge limit")
        icon: "battery-saver"
        description: !Battery.chargeLimitAvailable
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
                ? Translation.tr("Choose a charge limit supported by this device")
            : Battery.chargeLimitAdjustable
                ? Translation.tr("Limit maximum charge to preserve battery health")
                : Translation.tr("Use your device's built-in battery conservation mode (requires polkit)")
        enabled: Battery.chargeLimitSupported
            || Battery.chargeLimitManaged
            || root.requestedEnabled
        checked: root.requestedEnabled
        Component.onCompleted: _ready = true
        onCheckedChanged: {
            if (!_ready || checked === root.requestedEnabled)
                return
            if (root.staged)
                TlpSettingsService.stageChargeEnabled(checked, root.requestedThreshold)
            else
                Config.setNestedValue("battery.chargeLimit.enable", checked)
        }
    }

    WSettingsSpinBox {
        property bool _ready: false
        visible: Battery.chargeLimitContinuous
        enabled: root.requestedEnabled
        label: Translation.tr("Charge limit threshold")
        icon: "battery-saver"
        suffix: "%"
        from: Battery.chargeLimitMinimum
        to: Battery.chargeLimitMaximum
        stepSize: Battery.chargeLimitStepSize
        value: root.requestedThreshold
        Component.onCompleted: _ready = true
        onValueChanged: {
            if (!_ready || value === root.requestedThreshold)
                return
            if (root.staged)
                TlpSettingsService.stageChargeThreshold(value)
            else
                Config.setNestedValue("battery.chargeLimit.threshold", value)
        }
    }

    WSettingsDropdown {
        visible: Battery.chargeLimitDiscrete
        enabled: root.requestedEnabled
        label: Translation.tr("Charge limit threshold")
        icon: "battery-saver"
        currentValue: root.requestedThreshold
        options: Battery.chargeLimitAllowedValues.map(value => ({
            value: value,
            displayName: String(value) + "%"
        }))
        onSelected: newValue => {
            if (root.staged)
                TlpSettingsService.stageChargeThreshold(Number(newValue))
            else
                Config.setNestedValue("battery.chargeLimit.threshold", newValue)
        }
    }
}
