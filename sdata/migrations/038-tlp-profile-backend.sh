# Enable TLP's Power Profiles and radio backends.
# tlp-pd implements the standard Power Profiles D-Bus API; TLP documents PPD
# conflicts and recommends masking systemd-rfkill on Arch for radio switching.

MIGRATION_ID="038-tlp-profile-backend"
MIGRATION_TITLE="Enable TLP power management"
MIGRATION_DESCRIPTION="Enables TLP/tlp-pd, avoids conflicting Power Profiles daemons, and prepares TLP radio switching when tlp-rdw is installed."
MIGRATION_TARGET_FILE="systemd system services"
MIGRATION_REQUIRED=true

_tlp_unit_exists() {
  local unit=$1
  [[ -e "/usr/lib/systemd/system/${unit}" \
      || -e "/lib/systemd/system/${unit}" \
      || -L "/etc/systemd/system/${unit}" ]] \
      || systemctl cat "$unit" >/dev/null 2>&1
}

_tlp_unit_masked() {
  [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "masked" ]]
}

_tlp_profile_backend_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  command -v tlp >/dev/null 2>&1 || return 1
  _tlp_unit_exists tlp.service || return 1
  _tlp_unit_exists tlp-pd.service || return 1
}

_tlp_radio_backend_available() {
  command -v tlp-rdw >/dev/null 2>&1 || return 1
  _tlp_unit_exists NetworkManager-dispatcher.service || return 1
}

migration_check() {
  # Missing tlp-pd means this migration is not applicable yet.
  _tlp_profile_backend_available || return 1

  systemctl is-enabled --quiet tlp.service 2>/dev/null || return 0
  systemctl is-enabled --quiet tlp-pd.service 2>/dev/null || return 0

  # Do not leave competing PPD implementations enabled beside tlp-pd.
  if _tlp_unit_exists power-profiles-daemon.service \
      && ! _tlp_unit_masked power-profiles-daemon.service; then
    return 0
  fi
  if _tlp_unit_exists tuned-ppd.service \
      && ! _tlp_unit_masked tuned-ppd.service; then
    return 0
  fi

  if _tlp_radio_backend_available \
      && ! systemctl is-enabled --quiet NetworkManager-dispatcher.service 2>/dev/null; then
    return 0
  fi

  # Avoid systemd-rfkill racing TLP radio restoration on Arch.
  if _tlp_unit_exists systemd-rfkill.service \
      && ! _tlp_unit_masked systemd-rfkill.service; then
    return 0
  fi
  if _tlp_unit_exists systemd-rfkill.socket \
      && ! _tlp_unit_masked systemd-rfkill.socket; then
    return 0
  fi

  return 1
}

migration_preview() {
  echo -e "${STY_GREEN}+ Enable tlp.service when available${STY_RST}"
  echo -e "${STY_GREEN}+ Enable tlp-pd.service when available${STY_RST}"
  echo -e "${STY_GREEN}+ Mask conflicting power-profiles-daemon/tuned-ppd units when present${STY_RST}"
  echo -e "${STY_GREEN}+ Enable NetworkManager dispatcher when tlp-rdw is installed${STY_RST}"
  echo -e "${STY_GREEN}+ Mask systemd-rfkill service/socket when present${STY_RST}"
  echo ""
  echo "tlp-pd provides the standard Power Profiles D-Bus API used by iNiR."
  echo "tlp-rdw handles the network/dock radio rules exposed in Battery settings."
}

migration_diff() {
  echo "TLP:"
  if command -v tlp >/dev/null 2>&1; then
    tlp --version 2>/dev/null || true
  else
    echo "  not installed (migration not applicable)"
  fi
  echo ""
  echo "Services:"
  systemctl is-enabled tlp.service 2>/dev/null || echo "  tlp.service: disabled/missing"
  systemctl is-enabled tlp-pd.service 2>/dev/null || echo "  tlp-pd.service: disabled/missing"

  if _tlp_unit_exists power-profiles-daemon.service; then
    printf '  power-profiles-daemon.service: '
    systemctl is-enabled power-profiles-daemon.service 2>/dev/null || true
  fi
  if _tlp_unit_exists tuned-ppd.service; then
    printf '  tuned-ppd.service: '
    systemctl is-enabled tuned-ppd.service 2>/dev/null || true
  fi
  if _tlp_radio_backend_available; then
    printf '  NetworkManager-dispatcher.service: '
    systemctl is-enabled NetworkManager-dispatcher.service 2>/dev/null || true
  else
    echo "  tlp-rdw: unavailable (radio-event integration will be skipped)"
  fi
  for unit in systemd-rfkill.service systemd-rfkill.socket; do
    if _tlp_unit_exists "$unit"; then
      printf '  %s: ' "$unit"
      systemctl is-enabled "$unit" 2>/dev/null || true
    fi
  done
}

migration_apply() {
  local unit

  if ! _tlp_profile_backend_available; then
    echo "TLP/tlp-pd is not available on this installation; leaving the existing PowerProfiles backend unchanged."
    return 0
  fi

  # Stop competing PPD implementations before starting tlp-pd.
  for unit in power-profiles-daemon.service tuned-ppd.service; do
    if _tlp_unit_exists "$unit" && ! _tlp_unit_masked "$unit"; then
      pkg_sudo systemctl mask --now "$unit" || return 1
    fi
  done

  pkg_sudo systemctl enable --now tlp.service || return 1
  pkg_sudo systemctl enable --now tlp-pd.service || return 1

  if _tlp_radio_backend_available; then
    pkg_sudo systemctl enable NetworkManager-dispatcher.service || return 1
  fi

  for unit in systemd-rfkill.service systemd-rfkill.socket; do
    if _tlp_unit_exists "$unit" && ! _tlp_unit_masked "$unit"; then
      pkg_sudo systemctl mask --now "$unit" || return 1
    fi
  done

  if command -v tlp-stat >/dev/null 2>&1; then
    echo ""
    echo "TLP status after migration:"
    pkg_sudo tlp-stat -s 2>/dev/null || true
  fi
}
