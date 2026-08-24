# Install the root-owned TLP helper, schema and polkit action outside the
# user-writable Quickshell runtime; privileged writes stay helper-controlled.

MIGRATION_ID="037-battery-charge-limit-helper"
MIGRATION_TITLE="Install iNiR TLP settings backend"
MIGRATION_DESCRIPTION="Installs and updates the root-owned TLP helper, validation schema and polkit action."
MIGRATION_TARGET_FILE="/usr/libexec/inir-battery-charge-limit"
MIGRATION_REQUIRED=true

migration_check() {
  local helper="${REPO_ROOT}/assets/helpers/inir-battery-charge-limit"
  local policy="${REPO_ROOT}/assets/polkit/org.inir.battery-charge-limit.policy"
  local schema="${REPO_ROOT}/assets/tlp/tlp-settings-schema.json"
  local installed_helper="/usr/libexec/inir-battery-charge-limit"
  local installed_policy="/usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy"
  local installed_schema="/usr/share/inir/tlp-settings-schema.json"

  [[ -f "$helper" && -f "$policy" && -f "$schema" ]] || return 0
  [[ -x "$installed_helper" && -f "$installed_policy" && -f "$installed_schema" ]] || return 0
  cmp -s "$helper" "$installed_helper" || return 0
  cmp -s "$policy" "$installed_policy" || return 0
  cmp -s "$schema" "$installed_schema" || return 0
  return 1
}

migration_preview() {
  echo -e "${STY_GREEN}+ sync /usr/libexec/inir-battery-charge-limit${STY_RST}"
  echo -e "${STY_GREEN}+ sync /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy${STY_RST}"
  echo -e "${STY_GREEN}+ sync /usr/share/inir/tlp-settings-schema.json${STY_RST}"
}

migration_diff() {
  local helper="${REPO_ROOT}/assets/helpers/inir-battery-charge-limit"
  local policy="${REPO_ROOT}/assets/polkit/org.inir.battery-charge-limit.policy"
  local schema="${REPO_ROOT}/assets/tlp/tlp-settings-schema.json"
  local installed_helper="/usr/libexec/inir-battery-charge-limit"
  local installed_policy="/usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy"
  local installed_schema="/usr/share/inir/tlp-settings-schema.json"

  echo "Current:"
  if [[ -x "$installed_helper" ]] && cmp -s "$helper" "$installed_helper"; then
    echo "  helper: up to date"
  elif [[ -e "$installed_helper" ]]; then
    echo "  helper: outdated"
  else
    echo "  helper: missing"
  fi

  if [[ -f "$installed_policy" ]] && cmp -s "$policy" "$installed_policy"; then
    echo "  polkit action: up to date"
  elif [[ -e "$installed_policy" ]]; then
    echo "  polkit action: outdated"
  else
    echo "  polkit action: missing"
  fi

  if [[ -f "$installed_schema" ]] && cmp -s "$schema" "$installed_schema"; then
    echo "  schema: up to date"
  elif [[ -e "$installed_schema" ]]; then
    echo "  schema: outdated"
  else
    echo "  schema: missing"
  fi

  echo ""
  echo "After migration:"
  echo "  helper: synchronized from repository asset"
  echo "  polkit action: synchronized from repository asset"
  echo "  schema: synchronized from repository asset"
}

migration_apply() {
  if ! migration_check; then
    return 0
  fi

  local helper="${REPO_ROOT}/assets/helpers/inir-battery-charge-limit"
  local policy="${REPO_ROOT}/assets/polkit/org.inir.battery-charge-limit.policy"
  local schema="${REPO_ROOT}/assets/tlp/tlp-settings-schema.json"

  [[ -f "$helper" ]] || {
    echo "Battery charge-limit helper asset is missing: $helper" >&2
    return 1
  }
  [[ -f "$policy" ]] || {
    echo "Battery charge-limit polkit policy asset is missing: $policy" >&2
    return 1
  }
  [[ -f "$schema" ]] || {
    echo "TLP settings schema asset is missing: $schema" >&2
    return 1
  }

  pkg_sudo install -Dm755 "$helper" /usr/libexec/inir-battery-charge-limit || return 1
  pkg_sudo install -Dm644 "$policy" /usr/share/polkit-1/actions/org.inir.battery-charge-limit.policy || return 1
  pkg_sudo install -Dm644 "$schema" /usr/share/inir/tlp-settings-schema.json || return 1

  echo "iNiR TLP helper, schema and polkit action synchronized."
}
