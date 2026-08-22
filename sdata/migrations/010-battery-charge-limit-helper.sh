# Migration: Install the privileged battery charge-limit helper and polkit action
# The helper is deliberately installed outside the user-writable Quickshell runtime.
# QML invokes it through pkexec; the helper validates the backend/value and chooses
# the sysfs path itself so a compromised user config cannot turn this into arbitrary
# root file writes.

MIGRATION_ID="010-battery-charge-limit-helper"
MIGRATION_TITLE="Install battery charge-limit helper"
MIGRATION_DESCRIPTION="Installs the root-owned battery charge-limit helper and its polkit action."
MIGRATION_TARGET_FILE="/usr/libexec/inir-battery-charge-limit"
MIGRATION_REQUIRED=true

migration_check() {
  [[ -x /usr/libexec/inir-battery-charge-limit ]] || return 0
  [[ -f /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy ]] || return 0
  return 1
}

migration_preview() {
  echo -e "${STY_GREEN}+ /usr/libexec/inir-battery-charge-limit${STY_RST}"
  echo -e "${STY_GREEN}+ /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy${STY_RST}"
}

migration_diff() {
  echo "Current:"
  [[ -x /usr/libexec/inir-battery-charge-limit ]] \
    && echo "  helper: installed" \
    || echo "  helper: missing"
  [[ -f /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy ]] \
    && echo "  polkit action: installed" \
    || echo "  polkit action: missing"
  echo ""
  echo "After migration:"
  echo "  helper: /usr/libexec/inir-battery-charge-limit"
  echo "  polkit action: /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy"
}

migration_apply() {
  if ! migration_check; then
    return 0
  fi

  local helper="${REPO_ROOT}/assets/helpers/inir-battery-charge-limit"
  local policy="${REPO_ROOT}/assets/polkit/org.inir.battery-charge-limit.policy"

  [[ -f "$helper" ]] || {
    echo "Battery charge-limit helper asset is missing: $helper" >&2
    return 1
  }
  [[ -f "$policy" ]] || {
    echo "Battery charge-limit polkit policy asset is missing: $policy" >&2
    return 1
  }

  pkg_sudo install -Dm755 "$helper" /usr/libexec/inir-battery-charge-limit || return 1
  pkg_sudo install -Dm644 "$policy" /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy || return 1

  echo "Battery charge-limit helper and polkit action installed."
}
