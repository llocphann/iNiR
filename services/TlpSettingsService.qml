pragma ComponentBehavior: Bound
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

Singleton {
    id: root

    signal mutationFinished(string kind, bool success)

    readonly property string helperPath: "/usr/libexec/inir-battery-charge-limit"
    readonly property string schemaPath: Quickshell.shellPath("assets/tlp/tlp-settings-schema.json")

    // Keep the parsed schema as a plain JavaScript array. A QML list<var>
    // coerces nested arrays into sequence wrappers, for which Array.isArray()
    // is false; that made every category appear empty in the settings UI.
    property var categories: []
    readonly property var navigationCategories: {
        const preferredOrder = [
            "battery-care", "general", "processor", "graphics", "disks",
            "pcie", "usb", "network", "radio", "radio-device-wizard", "audio"
        ]
        const result = root._array(root.categories).slice()
        result.sort((left, right) => {
            const leftRank = preferredOrder.indexOf(String(left?.id ?? ""))
            const rightRank = preferredOrder.indexOf(String(right?.id ?? ""))
            return (leftRank < 0 ? preferredOrder.length : leftRank)
                - (rightRank < 0 ? preferredOrder.length : rightRank)
        })
        return result
    }
    property var effectiveValues: ({})
    property var managedValues: ({})
    // Platform-profile choices are runtime firmware capabilities, not a fixed list.
    property var runtimeValues: ({})
    property var pendingValues: ({})
    property var pendingChargePolicy: null
    property bool schemaLoaded: false
    property bool statusLoaded: false
    property bool available: false
    property bool supported: false
    property bool configAvailable: false
    property bool enabled: false
    property bool busy: false
    property string tlpVersion: ""
    property string statusReason: ""
    property string configFile: "/etc/tlp.d/99-inir-tlp-settings.conf"
    property string lastError: ""
    property bool _refreshPending: false
    property string _mutationKind: ""

    readonly property bool hasPendingChanges: Object.keys(root.pendingValues).length > 0
        || root.pendingChargePolicy !== null
    readonly property int pendingCount: Object.keys(root.pendingValues).length
        + (root.pendingChargePolicy !== null ? 1 : 0)
    readonly property int managedCount: Object.keys(root.managedValues).length
    readonly property bool managedConfigPresent: root.managedCount > 0
        || root.statusReason === "managed-config-invalid"
    readonly property bool canResetOverrides: root.managedConfigPresent
        && !root.hasPendingChanges
        && !root.busy

    function _clone(value): var {
        return JSON.parse(JSON.stringify(value ?? {}))
    }

    function _clearStatus(reason: string): void {
        root.statusLoaded = false
        root.available = false
        root.supported = false
        root.configAvailable = false
        root.enabled = false
        root.tlpVersion = ""
        root.statusReason = reason
        root.effectiveValues = ({})
        root.managedValues = ({})
        root.runtimeValues = ({})
    }

    function _array(value): var {
        if (value === undefined || value === null)
            return []
        try {
            return Array.from(value)
        } catch (error) {
            return []
        }
    }

    function _versionMinor(version: string): int {
        const parts = String(version ?? "").split(".")
        if (parts.length < 2 || Number(parts[0]) !== 1)
            return -1
        const minor = Number(parts[1])
        return Number.isFinite(minor) ? minor : -1
    }

    function _keepUnavailableSetting(key: string): bool {
        return root.isManaged(key)
            || Object.prototype.hasOwnProperty.call(root.pendingValues, key)
    }

    function settingAvailable(definition): bool {
        const key = String(definition?.key ?? "")
        const required = String(definition?.minVersion ?? "")
        if (required) {
            const currentMinor = root._versionMinor(root.tlpVersion)
            const requiredMinor = root._versionMinor(required)
            if (currentMinor < 0 || requiredMinor < 0 || currentMinor < requiredMinor)
                return false
        }

        if (key.startsWith("DISK_IDLE_SECS_")) {
            // TLP 1.10 discourages this legacy setting and kernel 7.0 ignores it;
            // keep only an owned/staged row so an old override remains removable.
            return root._keepUnavailableSetting(key)
        }

        if (key.startsWith("PLATFORM_PROFILE_")
                && root.statusLoaded
                && Object.prototype.hasOwnProperty.call(root.runtimeValues, key)
                && root._array(root.runtimeValues[key]).length === 0) {
            // Intrinsic defaults can exist without firmware support; keep only
            // owned/staged rows so stale overrides remain removable.
            return root._keepUnavailableSetting(key)
        }

        const capabilityValues = TlpRuntimeCapabilities.values
        if (Object.prototype.hasOwnProperty.call(capabilityValues, key)
                && root._array(capabilityValues[key]).length === 0)
            return root._keepUnavailableSetting(key)

        if (TlpRuntimeCapabilities.isRdwSetting(key)
                && TlpRuntimeCapabilities.rdwProbeDone
                && !TlpRuntimeCapabilities.rdwAvailable)
            return root._keepUnavailableSetting(key)

        return true
    }

    function settingsForCategory(category): var {
        const settings = root._array(category?.settings)
        return settings
            .filter(setting => root.settingAvailable(setting))
            .map(setting => {
                const multipleFrom = String(setting?.multipleFromVersion ?? "")
                if (!multipleFrom)
                    return setting
                const currentMinor = root._versionMinor(root.tlpVersion)
                const requiredMinor = root._versionMinor(multipleFrom)
                if (currentMinor < requiredMinor)
                    return setting
                const adapted = root._clone(setting)
                adapted.type = "list"
                return adapted
            })
    }

    function categoryLabel(category): string {
        const id = String(category?.id ?? "")
        const labels = ({
            "battery-care": "Battery care",
            "disks": "Storage",
            "pcie": "PCIe devices",
            "radio": "Radios",
            "radio-device-wizard": "Radio events"
        })
        return labels[id] ?? String(category?.name ?? id)
    }

    function groupsForCategory(category, filterText): var {
        const settings = root.settingsForCategory(category)
        const metadata = root._array(category?.groups)
        const metadataById = ({})
        for (const entry of metadata)
            metadataById[String(entry?.id ?? "")] = entry

        const orderedIds = []
        const grouped = ({})
        for (const setting of settings) {
            const groupId = String(setting?.group ?? setting?.key ?? "")
            if (!Object.prototype.hasOwnProperty.call(grouped, groupId)) {
                const meta = metadataById[groupId] ?? ({})
                grouped[groupId] = {
                    id: groupId,
                    title: root.groupLabel(groupId, String(meta.title ?? "")),
                    description: String(meta.description ?? ""),
                    settings: []
                }
                orderedIds.push(groupId)
            }
            grouped[groupId].settings.push(setting)
        }

        for (const groupId of orderedIds) {
            if (groupId === "TLP_PROFILE")
                continue
            const group = grouped[groupId]
            const profiled = group.settings.filter(setting => {
                const profile = String(setting?.profile ?? "")
                return profile === "AC" || profile === "BAT" || profile === "SAV"
            })
            if (profiled.length < 2)
                continue
            const guidance = "When overriding this group, set every shown profile together to avoid values spilling between TLP profiles."
            group.description = group.description.length > 0
                ? group.description + " " + guidance
                : guidance
        }

        const query = String(filterText ?? "").trim().toLowerCase()
        return orderedIds.map(groupId => {
            const group = grouped[groupId]
            if (!query)
                return group

            const groupMatches = group.id.toLowerCase().includes(query)
                || group.title.toLowerCase().includes(query)
                || group.description.toLowerCase().includes(query)
            if (groupMatches)
                return group

            const adapted = root._clone(group)
            adapted.settings = group.settings.filter(setting =>
                String(setting?.key ?? "").toLowerCase().includes(query)
                || String(setting?.description ?? "").toLowerCase().includes(query)
                || root.settingLabel(setting).toLowerCase().includes(query))
            return adapted
        }).filter(group => group.settings.length > 0)
    }

    function settingLabel(definition): string {
        const acronyms = ({
            TLP: "TLP", CPU: "CPU", GPU: "GPU", AMDGPU: "AMD GPU",
            USB: "USB", PCIE: "PCIe", WIFI: "Wi-Fi", WOL: "Wake-on-LAN",
            SATA: "SATA", AHCI: "AHCI", APM: "APM", PM: "PM",
            NMI: "NMI", HWP: "HWP", DPM: "DPM", IOSCHED: "I/O scheduler"
        })
        let key = String(definition?.key ?? "")
        if (key.startsWith("TLP_PROFILE_") && String(definition?.profile ?? "").length > 0)
            key = "TLP_PROFILE"
        key = key.replace(/_ON_(AC|BAT|SAV)/, "")
            .replace(/_DEFAULT$/, "")
        return key.split("_").filter(Boolean).map(word => {
            if (Object.prototype.hasOwnProperty.call(acronyms, word))
                return acronyms[word]
            if (word === "MIN") return "Minimum"
            if (word === "MAX") return "Maximum"
            if (word === "PWR") return "Power"
            if (word === "FREQ") return "Frequency"
            if (word === "SECS") return "Seconds"
            if (word === "OPMODE") return "Mode"
            if (word === "PERF") return "Performance"
            if (word === "POWEROFF") return "Power off"
            return word.charAt(0) + word.slice(1).toLowerCase()
        }).join(" ")
    }

    function groupLabel(groupId: string, fallbackTitle: string): string {
        const labels = ({
            TLP_ENABLE: "TLP power management",
            TLP_DISABLE_DEFAULTS: "Intrinsic defaults",
            TLP_WARN_LEVEL: "Warnings",
            TLP_MSG_COLORS: "Message colors",
            TLP_AUTO_SWITCH: "Automatic profile switching",
            TLP_PROFILE: "Power profiles",
            TLP_PS_IGNORE: "Power-source detection",
            SOUND_POWER_SAVE: "Audio power saving",
            SOUND_POWER_SAVE_CONTROLLER: "Audio controller",
            DISK_IDLE_SECS: "Disk idle sync",
            MAX_LOST_WORK_SECS: "Writeback interval",
            DISK_DEVICES: "Target disks",
            DISK_APM_LEVEL: "Disk APM level",
            DISK_APM_CLASS_DENYLIST: "APM exclusions",
            DISK_SPINDOWN_TIMEOUT: "Disk spin-down",
            DISK_IOSCHED: "I/O scheduler",
            SATA_LINKPWR: "SATA link power",
            SATA_LINKPWR_DENYLIST: "SATA link exclusions",
            AHCI_RUNTIME_PM: "Disk runtime power",
            AHCI_RUNTIME_PM_TIMEOUT: "Runtime suspend delay",
            BAY_POWEROFF: "Optical-drive power",
            BAY_DEVICE: "Optical-drive device",
            INTEL_GPU_POWER_PROFILE: "Intel GPU power profile",
            INTEL_GPU_FREQ: "Intel GPU frequencies",
            RADEON_DPM_PERF_LEVEL: "AMD GPU performance level",
            AMDGPU_ABM_LEVEL: "AMD panel power saving",
            WIFI_PWR: "Wi-Fi power saving",
            WOL_DISABLE: "Wake-on-LAN",
            PCIE_ASPM: "PCIe link power",
            RUNTIME_PM: "PCIe runtime power",
            RUNTIME_PM_DENYLIST: "PCIe device exclusions",
            RUNTIME_PM_DRIVER_DENYLIST: "PCIe driver exclusions",
            RUNTIME_PM_DEVICE: "Forced PCIe runtime state",
            CPU_DRIVER_OPMODE: "CPU driver mode",
            CPU_SCALING_GOVERNOR: "CPU scaling governor",
            CPU_SCALING_FREQ: "CPU frequency limits",
            CPU_ENERGY_PERF_POLICY: "CPU energy policy",
            CPU_PERF: "CPU performance limits",
            CPU_BOOST: "CPU boost",
            CPU_HWP_DYN_BOOST: "Intel HWP dynamic boost",
            NMI_WATCHDOG: "NMI watchdog",
            PLATFORM_PROFILE: "Platform profile",
            MEM_SLEEP: "Suspend mode",
            DEVICES_TO_DISABLE_ON_STARTUP: "Disable radios at startup",
            DEVICES_TO_ENABLE_ON_STARTUP: "Enable radios at startup",
            DEVICES_TO_ENABLE_ON_AC: "Radios on AC",
            DEVICES_TO_DISABLE_ON_BAT: "Radios on battery",
            DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE: "Idle radios on battery",
            PROFILE_RADIO: "Profile-based radio rules",
            DEVICES_TO_DISABLE_ON_CONNECT: "On network connect",
            DEVICES_TO_ENABLE_ON_DISCONNECT: "On network disconnect",
            DEVICES_ON_DOCK: "On dock",
            DEVICES_ON_UNDOCK: "On undock",
            USB_AUTOSUSPEND: "USB autosuspend",
            USB_DENYLIST: "USB autosuspend exclusions",
            USB_EXCLUDE_AUDIO: "USB audio",
            USB_EXCLUDE_BTUSB: "USB Bluetooth",
            USB_EXCLUDE_PHONE: "USB phones",
            USB_EXCLUDE_PRINTER: "USB printers",
            USB_EXCLUDE_WWAN: "USB WWAN",
            USB_ALLOWLIST: "USB autosuspend allowlist",
            RESTORE_THRESHOLDS_ON_BAT: "Restore charge thresholds"
        })
        if (Object.prototype.hasOwnProperty.call(labels, groupId))
            return labels[groupId]
        const generated = root.settingLabel({ key: groupId })
        return generated.length > 0 ? generated : String(fallbackTitle ?? "")
    }

    function groupUsesCompactProfileRows(group): bool {
        const settings = root._array(group?.settings)
        if (settings.length < 2)
            return false
        const firstLabel = root.settingLabel(settings[0])
        if (!firstLabel)
            return false
        return settings.every(setting =>
            String(setting?.profile ?? "").length > 0
            && root.settingLabel(setting) === firstLabel)
    }

    function exampleValue(definition): string {
        const examples = ({
            TLP_MSG_COLORS: "91 93 1 92",
            DISK_DEVICES: "nvme0n1 sda",
            DISK_APM_LEVEL_ON_AC: "254 254",
            DISK_APM_LEVEL_ON_BAT: "128 128",
            DISK_SPINDOWN_TIMEOUT_ON_AC: "0 0",
            DISK_SPINDOWN_TIMEOUT_ON_BAT: "0 0",
            DISK_IOSCHED: "keep",
            SATA_LINKPWR_DENYLIST: "host1",
            BAY_DEVICE: "sr0",
            RUNTIME_PM_DENYLIST: "11:22.3 44:55.6",
            RUNTIME_PM_DRIVER_DENYLIST: "amdgpu mei_me nouveau nvidia xhci_hcd",
            RUNTIME_PM_ENABLE: "11:22.3",
            RUNTIME_PM_DISABLE: "44:55.6",
            CPU_SCALING_MIN_FREQ_ON_AC: "0",
            CPU_SCALING_MAX_FREQ_ON_AC: "0",
            CPU_SCALING_MIN_FREQ_ON_BAT: "0",
            CPU_SCALING_MAX_FREQ_ON_BAT: "0",
            CPU_SCALING_MIN_FREQ_ON_SAV: "0",
            CPU_SCALING_MAX_FREQ_ON_SAV: "0",
            USB_DENYLIST: "1111:2222 3333:4444",
            USB_ALLOWLIST: "1111:2222 3333:4444"
        })
        return String(examples[String(definition?.key ?? "")] ?? "")
    }

    function optionValues(definition): var {
        const key = String(definition?.key ?? "")
        const capabilityValues = TlpRuntimeCapabilities.values
        const hasCapabilityValues = Object.prototype.hasOwnProperty.call(capabilityValues, key)
        const hasHelperRuntimeValues = Object.prototype.hasOwnProperty.call(root.runtimeValues, key)
        const result = hasCapabilityValues
            ? root._array(capabilityValues[key]).map(value => String(value))
            : hasHelperRuntimeValues
                ? root._array(root.runtimeValues[key]).map(value => String(value))
                : root._array(definition?.values).map(value => String(value))

        // TLP documents "userspace" here even though TLPUI 1.10 omits it.
        if (!hasCapabilityValues
                && key.startsWith("CPU_SCALING_GOVERNOR_")
                && !result.includes("userspace"))
            result.push("userspace")

        // Preserve stale owned/staged values so users can still unset them.
        const current = String(root.value(key) ?? "").trim()
        if (current.length > 0) {
            for (const token of current.split(/\s+/)) {
                if (token.length > 0 && !result.includes(token))
                    result.push(token)
            }
        }
        return result
    }

    function profileLabel(profile): string {
        switch (String(profile ?? "")) {
        case "AC": return "AC"
        case "BAT": return "Battery"
        case "SAV": return "Power saver"
        case "DEFAULT": return "Fallback"
        default: return ""
        }
    }

    function displayValue(definition, value): string {
        const raw = String(value ?? "")
        const key = String(definition?.key ?? "")
        if (key === "TLP_WARN_LEVEL") {
            const labels = ({
                "0": "Disabled", "1": "Background only",
                "2": "Commands only", "3": "Background and commands"
            })
            return labels[raw] ?? raw
        }
        if (key === "TLP_AUTO_SWITCH") {
            const labels = ({ "0": "Disabled", "1": "Automatic", "2": "Smart" })
            return labels[raw] ?? raw
        }
        if (key === "TLP_DISABLE_DEFAULTS")
            return raw === "1" ? "Disable intrinsic defaults" : "Use intrinsic defaults"
        if (key === "WOL_DISABLE") {
            const labels = ({ N: "Allow Wake-on-LAN", Y: "Disable Wake-on-LAN" })
            return labels[raw] ?? raw
        }
        if (key === "SOUND_POWER_SAVE_CONTROLLER") {
            const labels = ({ N: "Keep controller active", Y: "Power down controller" })
            return labels[raw] ?? raw
        }
        if (key.startsWith("BAY_POWEROFF_")) {
            const labels = ({ "0": "Keep drive powered", "1": "Power off drive" })
            return labels[raw] ?? raw
        }
        if (key.startsWith("USB_EXCLUDE_")) {
            const labels = ({ "0": "Allow autosuspend", "1": "Exclude from autosuspend" })
            return labels[raw] ?? raw
        }
        if (key.startsWith("TLP_PROFILE_")) {
            const labels = ({
                AC: "AC (legacy)", PRF: "Performance", BAT: "Battery (legacy)",
                BAL: "Balanced", SAV: "Power saver"
            })
            return labels[raw] ?? raw
        }
        const common = ({
            "0": "Disabled", "1": "Enabled", N: "No", Y: "Yes",
            off: "Off", on: "On", auto: "Automatic", default: "System default",
            power_saving: "Power saving", powersave: "Power saving",
            powersupersave: "Maximum power saving", performance: "Performance",
            balanced: "Balanced", "balanced-performance": "Balanced performance",
            "low-power": "Low power", quiet: "Quiet", cool: "Cool",
            balance_performance: "Balanced performance", balance_power: "Balanced power",
            power: "Maximum power saving", active: "Active", passive: "Passive",
            guided: "Guided", s2idle: "s2idle (light sleep)",
            deep: "deep (suspend to RAM)", min_power: "Minimum power",
            med_power_with_dipm: "Medium power with DIPM",
            medium_power: "Medium power", max_performance: "Maximum performance",
            bluetooth: "Bluetooth", nfc: "NFC", wifi: "Wi-Fi", wwan: "WWAN",
            userspace: "Userspace", keep: "Keep current/default", _: "Keep current/default"
        })
        return common[raw] ?? raw.replace(/_/g, " ")
    }

    function settingNotice(definition): string {
        const key = String(definition?.key ?? "")
        const current = String(root.value(key) ?? "")
        if (key === "TLP_ENABLE" && current === "0")
            return "A reboot is required for complete restoration after disabling TLP."
        if (key === "WOL_DISABLE" && current === "N")
            return "Allowing Wake-on-LAN requires a reboot before the new setting is fully effective."
        if (key.startsWith("DISK_IDLE_SECS_"))
            return "Legacy laptop-mode setting: TLP recommends not changing it, and kernel 7.0 ignores it. Disable this override unless you explicitly need legacy behavior."
        if (key.startsWith("MEM_SLEEP_"))
            return "Changing the system suspend mode can cause instability or data loss on unsupported hardware."
        return ""
    }

    function isManaged(key: string): bool {
        const pending = root.pendingValues[key]
        if (pending !== undefined)
            return pending.managed === true
        return Object.prototype.hasOwnProperty.call(root.managedValues, key)
    }

    function value(key: string): string {
        const pending = root.pendingValues[key]
        if (pending !== undefined) {
            if (pending.managed === true)
                return String(pending.value ?? "")
            // Inherited post-Apply state is authoritative only after TLP re-reads config.
            return String(root.effectiveValues[key] ?? root.managedValues[key] ?? "")
        }
        if (Object.prototype.hasOwnProperty.call(root.managedValues, key))
            return String(root.managedValues[key] ?? "")
        return String(root.effectiveValues[key] ?? "")
    }

    function effectiveValue(key: string): string {
        return String(root.effectiveValues[key] ?? "")
    }

    function chargeEnabled(): bool {
        void Config.revision
        if (root.pendingChargePolicy !== null)
            return root.pendingChargePolicy.enabled === true
        return Config.options?.battery?.chargeLimit?.enable ?? false
    }

    function chargeThreshold(): int {
        void Config.revision
        if (root.pendingChargePolicy !== null)
            return Number(root.pendingChargePolicy.threshold ?? 80)
        return Number(Config.options?.battery?.chargeLimit?.threshold ?? 80)
    }

    function _stageChargePolicy(enabled: bool, threshold: int): void {
        void Config.revision
        const originalEnabled = Config.options?.battery?.chargeLimit?.enable ?? false
        const originalThreshold = Number(Config.options?.battery?.chargeLimit?.threshold ?? 80)
        const normalizedThreshold = Math.max(1, Math.min(100, Math.round(Number(threshold))))
        if (enabled === originalEnabled && normalizedThreshold === originalThreshold)
            root.pendingChargePolicy = null
        else
            root.pendingChargePolicy = {
                enabled: enabled,
                threshold: normalizedThreshold
            }
        root.lastError = ""
    }

    function stageChargeEnabled(enabled: bool, threshold: int): void {
        root._stageChargePolicy(enabled, threshold)
    }

    function stageChargeThreshold(threshold: int): void {
        root._stageChargePolicy(root.chargeEnabled(), threshold)
    }

    function stageSet(key: string, value): void {
        const next = root._clone(root.pendingValues)
        const normalized = String(value ?? "")
        if (Object.prototype.hasOwnProperty.call(root.managedValues, key)
                && String(root.managedValues[key] ?? "") === normalized)
            delete next[key]
        else
            next[key] = { managed: true, value: normalized }
        root.pendingValues = next
        root.lastError = ""
    }

    function stageUnset(key: string): void {
        const next = root._clone(root.pendingValues)
        if (Object.prototype.hasOwnProperty.call(root.managedValues, key))
            next[key] = { managed: false, value: "" }
        else
            delete next[key]
        root.pendingValues = next
        root.lastError = ""
    }

    function discard(): void {
        root.pendingValues = ({})
        root.pendingChargePolicy = null
        root.lastError = ""
    }

    function refresh(): void {
        if (statusProcess.running || root.busy) {
            root._refreshPending = true
            return
        }
        root._refreshPending = false
        statusProcess.running = true
    }

    function _startApply(kind: string): bool {
        if (root.busy || !root.hasPendingChanges)
            return false

        const command = ["/usr/bin/pkexec", root.helperPath, "--config-apply"]
        if (root.pendingChargePolicy !== null) {
            if (root.pendingChargePolicy.enabled === true)
                command.push("--charge-set", String(root.pendingChargePolicy.threshold ?? 80))
            else
                command.push("--charge-disable")
        }
        const keys = Object.keys(root.pendingValues).sort()
        for (const key of keys) {
            const operation = root.pendingValues[key]
            if (operation.managed === true)
                command.push("--set", key, String(operation.value ?? ""))
            else
                command.push("--unset", key)
        }

        root.busy = true
        root.lastError = ""
        root._mutationKind = kind
        mutationProcess.command = command
        mutationProcess.running = true
        return true
    }

    function apply(): bool {
        return root._startApply("apply")
    }

    function reset(): void {
        if (root.busy)
            return
        root.busy = true
        root.lastError = ""
        root._mutationKind = "reset"
        mutationProcess.command = ["/usr/bin/pkexec", root.helperPath, "--config-reset"]
        mutationProcess.running = true
    }

    function _parseStatus(payload: string): void {
        let data
        try {
            data = JSON.parse(String(payload ?? "").trim())
        } catch (error) {
            root._clearStatus("invalid-status")
            return
        }

        if (data?.schema !== 1) {
            root._clearStatus("invalid-status")
            return
        }

        root.available = data.available === true
        root.supported = data.supported === true
        root.configAvailable = data.configAvailable === true
        root.enabled = data.enabled === true
        root.tlpVersion = String(data.tlpVersion ?? "")
        root.statusReason = String(data.reason ?? "")
        root.configFile = String(data.configFile ?? root.configFile)
        root.effectiveValues = root._clone(data.effective)
        root.managedValues = root._clone(data.managed)
        root.runtimeValues = root._clone(data.runtimeValues)
        root.statusLoaded = true
    }

    FileView {
        id: schemaFile
        path: root.schemaPath

        onLoaded: {
            try {
                const data = JSON.parse(schemaFile.text())
                if (data?.schema !== 1 || !Array.isArray(data.categories))
                    throw new Error("unsupported schema")
                root.categories = data.categories
                root.schemaLoaded = true
                root.refresh()
            } catch (error) {
                root.categories = []
                root.schemaLoaded = false
                root._clearStatus("schema-invalid")
                console.warn("[TLP Settings] Failed to load schema:", error)
            }
        }

        onLoadFailed: error => {
            root.categories = []
            root.schemaLoaded = false
            root._clearStatus("schema-unavailable")
            console.warn("[TLP Settings] Schema is unavailable:", error)
        }
    }

    Process {
        id: statusProcess
        command: [root.helperPath, "--config-status"]

        stdout: StdioCollector {
            id: statusOutput
        }

        stderr: StdioCollector {
            id: statusError
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0)
                root._parseStatus(statusOutput.text)
            else {
                root._clearStatus("status-failed")
                root.lastError = statusError.text.trim()
            }

            if (root._refreshPending)
                Qt.callLater(() => root.refresh())
        }
    }

    Process {
        id: mutationProcess

        stdout: StdioCollector {
            id: mutationOutput
        }

        stderr: StdioCollector {
            id: mutationError
        }

        onExited: (exitCode, exitStatus) => {
            const kind = root._mutationKind
            const success = exitCode === 0
            const appliedChargePolicy = root.pendingChargePolicy === null
                ? null : root._clone(root.pendingChargePolicy)
            root.busy = false
            if (success) {
                root.pendingValues = ({})
                if (kind === "apply") {
                    root.pendingChargePolicy = null
                    if (appliedChargePolicy !== null) {
                        // Refresh authoritative status before Config can reconcile again.
                        TlpService.refresh()
                        Config.setNestedValues({
                            "battery.chargeLimit.enable": appliedChargePolicy.enabled === true,
                            "battery.chargeLimit.threshold": Number(appliedChargePolicy.threshold ?? 80)
                        })
                    }
                }
                root.lastError = ""
            } else {
                const detail = mutationError.text.trim() || mutationOutput.text.trim()
                root.lastError = detail || "TLP settings operation failed (exit code " + exitCode + ")"
                console.warn("[TLP Settings]", root.lastError)
            }
            root._mutationKind = ""
            root.refresh()
            root.mutationFinished(kind, success)
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.schemaLoaded
        onTriggered: root.refresh()
    }
}
