# Migration: Enable TLP and its power-profiles-daemon-compatible backend
# TLP 1.9+ provides tlp-pd, which implements the same D-Bus API used by
# Quickshell.Services.UPower.PowerProfiles. This lets the existing iNiR power
# profile UI keep using the native PowerProfiles API while TLP owns the actual
# kernel power-management settings.

MIGRATION_ID="013-tlp-profile-backend"
MIGRATION_TITLE="Enable TLP power management"
MIGRATION_DESCRIPTION="Enables TLP and tlp-pd so iNiR's existing Power Profile controls are backed by TLP instead of power-profiles-daemon."
MIGRATION_TARGET_FILE="systemd user/system services"
MIGRATION_REQUIRED=true

migration_check() {
  command -v tlp >/dev/null 2>&1 || return 0
  systemctl is-enabled --quiet tlp.service 2>/dev/null && \
    systemctl is-enabled --quiet tlp-pd.service 2>/dev/null && return 1
  return 0
}

migration_preview() {
  echo -e "${STY_GREEN}+ Enable tlp.service${STY_RST}"
  echo -e "${STY_GREEN}+ Enable tlp-pd.service${STY_RST}"
  echo ""
  echo "tlp-pd provides the standard power-profiles D-Bus API used by iNiR."
}

migration_diff() {
  echo "TLP:"
  if command -v tlp >/dev/null 2>&1; then
    tlp --version 2>/dev/null || true
  else
    echo "  not installed"
  fi
  echo ""
  echo "Services:"
  systemctl is-enabled tlp.service 2>/dev/null || echo "  tlp.service: disabled/missing"
  systemctl is-enabled tlp-pd.service 2>/dev/null || echo "  tlp-pd.service: disabled/missing"
}

migration_apply() {
  if ! command -v tlp >/dev/null 2>&1; then
    echo -e "${STY_YELLOW}TLP is not installed; dependency installation must run before this migration.${STY_RST}"
    return 1
  fi

  systemctl list-unit-files tlp.service >/dev/null 2>&1 || {
    echo -e "${STY_RED}TLP service unit is missing.${STY_RST}"
    return 1
  }

  systemctl list-unit-files tlp-pd.service >/dev/null 2>&1 || {
    echo -e "${STY_RED}TLP profile daemon service is missing. Install tlp-pd (TLP 1.9+).${STY_RST}"
    return 1
  }

  pkg_sudo systemctl enable --now tlp.service || return 1
  pkg_sudo systemctl enable --now tlp-pd.service || return 1

  if command -v tlp-stat >/dev/null 2>&1; then
    echo ""
    echo "TLP status after migration:"
    tlp-stat -s 2>/dev/null || true
  fi
}
