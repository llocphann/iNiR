pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower
import qs.modules.common
import qs.modules.common.functions
import qs.services

Singleton {
    id: root

    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1") console.log(...args);
    }

    property bool available: UPower.displayDevice.isLaptopBattery
    property var chargeState: UPower.displayDevice.state
    property bool isCharging: chargeState == UPowerDeviceState.Charging
    property bool isPluggedIn: isCharging || chargeState == UPowerDeviceState.PendingCharge
    // Discharging-based, not !isPluggedIn: FullyCharged on AC must not count as "on battery"
    readonly property bool onBattery: available && (chargeState == UPowerDeviceState.Discharging || chargeState == UPowerDeviceState.PendingDischarge)
    property real percentage: UPower.displayDevice?.percentage ?? 1
    readonly property bool allowAutomaticSuspend: Config.options?.battery?.automaticSuspend ?? false
    readonly property bool soundEnabled: Config.options?.sounds?.battery ?? true

    property bool isLow: available && (percentage <= ((Config.options?.battery?.low ?? 20) / 100))
    property bool isCritical: available && (percentage <= ((Config.options?.battery?.critical ?? 10) / 100))
    property bool isSuspending: available && (percentage <= ((Config.options?.battery?.suspend ?? 5) / 100))
    property bool isFull: available && (percentage >= ((Config.options?.battery?.full ?? 95) / 100))

    property bool isLowAndNotCharging: isLow && !isCharging
    property bool isCriticalAndNotCharging: isCritical && !isCharging
    property bool isSuspendingAndNotCharging: allowAutomaticSuspend && isSuspending && !isCharging
    property bool isFullAndCharging: isFull && isCharging

    property real energyRate: UPower.displayDevice.changeRate
    property real timeToEmpty: UPower.displayDevice.timeToEmpty
    property real timeToFull: UPower.displayDevice.timeToFull

    // ─── Charge limit ───
    readonly property bool chargeLimitEnabled: {
        void Config.revision
        return Config.options?.battery?.chargeLimit?.enable ?? false
    }
    readonly property int chargeLimitThreshold: {
        void Config.revision
        return Config.options?.battery?.chargeLimit?.threshold ?? 80
    }
    readonly property bool chargeLimitAvailable: TlpService.available
    readonly property bool chargeLimitSupported: TlpService.supported
    readonly property bool chargeLimitAdjustable: TlpService.adjustable
    readonly property bool chargeLimitStateKnown: TlpService.stateKnown
    readonly property bool chargeLimitActive: TlpService.active
    readonly property bool chargeLimitManaged: TlpService.managed
    readonly property int currentChargeLimit: TlpService.currentLimit
    readonly property int effectiveChargeLimitThreshold: TlpService.effectiveRequestedLimit
    readonly property string chargeLimitKind: TlpService.limitKind
    readonly property bool chargeLimitContinuous: TlpService.continuous
    readonly property bool chargeLimitDiscrete: TlpService.discrete
    readonly property int chargeLimitMinimum: TlpService.minimumLimit
    readonly property int chargeLimitMaximum: TlpService.maximumLimit
    readonly property int chargeLimitStepSize: TlpService.limitStepSize
    readonly property var chargeLimitAllowedValues: TlpService.allowedLimits
    readonly property string chargeLimitStatusReason: TlpService.statusReason

    // ─── Battery warnings ───
    onIsLowAndNotChargingChanged: {
        if (!root.available || !isLowAndNotCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send", 
            Translation.tr("Low battery"), 
            Translation.tr("Consider plugging in your device"), 
            "-u", "critical",
            "-a", "Shell",
            "--hint=int:transient:1",
        ])

        if (root.soundEnabled) Audio.playEvent("batteryLow");
    }

    onIsCriticalAndNotChargingChanged: {
        if (!root.available || !isCriticalAndNotCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send", 
            Translation.tr("Critically low battery"), 
            Translation.tr("Please charge!\nAutomatic suspend triggers at %1%").arg(Config.options?.battery?.suspend ?? 5), 
            "-u", "critical",
            "-a", "Shell",
            "--hint=int:transient:1",
        ]);

        if (root.soundEnabled) Audio.playEvent("batteryCritical");
    }

    onIsSuspendingAndNotChargingChanged: {
        if (root.available && isSuspendingAndNotCharging) {
            Session.suspend()
        }
    }

    onIsFullAndChargingChanged: {
        if (!root.available || !isFullAndCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send",
            Translation.tr("Battery full"),
            Translation.tr("Please unplug the charger"),
            "-a", "Shell",
            "--hint=int:transient:1",
        ]);

        if (root.soundEnabled) Audio.playEvent("batteryFull");
    }

    onIsPluggedInChanged: {
        if (!root.available || !root.soundEnabled) return;
        if (isPluggedIn) {
            Audio.playEvent("powerPlug")
        } else {
            Audio.playEvent("powerUnplug")
        }
    }
}
