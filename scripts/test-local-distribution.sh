#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_root="$(cd -- "$script_dir/.." && pwd)"
launcher="${INIR_LAUNCHER_PATH:-$runtime_root/scripts/inir}"

run_runtime=false
if [[ "${1:-}" == "--with-runtime" ]]; then
    run_runtime=true
fi

step() {
    printf '\n== %s ==\n' "$1"
}

step "shell syntax"
bash -n \
    "$runtime_root/setup" \
    "$runtime_root/scripts/inir" \
    "$runtime_root/scripts/test-tlp-integration-lifecycle.sh" \
    "$runtime_root/scripts/test-tlp-settings-ui-guards.sh" \
    "$runtime_root/scripts/test-update-lifecycle.sh" \
    "$runtime_root/sdata/lib/"*.sh \
    "$runtime_root/sdata/subcmd-install/"*.sh \
    "$runtime_root/sdata/migrations/"*.sh
sh -n \
    "$runtime_root/assets/helpers/inir-battery-charge-limit" \
    "$runtime_root/scripts/test-battery-charge-limit-helper.sh"

step "battery charge-limit helper"
sh "$runtime_root/scripts/test-battery-charge-limit-helper.sh"

step "TLP integration lifecycle"
bash "$runtime_root/scripts/test-tlp-integration-lifecycle.sh"

step "TLP settings UI guards"
bash "$runtime_root/scripts/test-tlp-settings-ui-guards.sh"

step "update lifecycle regression"
bash "$runtime_root/scripts/test-update-lifecycle.sh"

step "session tray ordering"
service_unit="$runtime_root/assets/systemd/inir.service"
if ! grep -qx 'Type=dbus' "$service_unit" \
        || ! grep -qx 'BusName=org.kde.StatusNotifierWatcher' "$service_unit" \
        || ! grep -qx 'Before=graphical-session.target' "$service_unit" \
        || grep -qx 'After=graphical-session.target' "$service_unit" \
        || grep -qx 'Requisite=graphical-session.target' "$service_unit"; then
    printf 'FAIL: inir.service does not gate XDG autostart on the tray watcher\n' >&2
    exit 1
fi
if ! grep -Fq 'property var _trayService: TrayService' "$runtime_root/shell.qml"; then
    printf 'FAIL: shell startup does not instantiate the StatusNotifier watcher\n' >&2
    exit 1
fi

step "fresh install defaults"
python3 - "$runtime_root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
with (root / "defaults/config.json").open(encoding="utf-8") as handle:
    config = json.load(handle)
schema = (root / "modules/common/Config.qml").read_text(encoding="utf-8")
wizard = (root / "welcome.qml").read_text(encoding="utf-8")

checks = {
    "settings rail": config["settingsUi"]["overlayStyle"] == "rail",
    "balanced profile": config["welcomeWizard"]["profile"] == "balanced",
    "iNiR Alt+Tab opt-in": config["modules"]["altSwitcher"] is False,
    "dock enabled": config["dock"]["enable"] is True,
    "dock pinned": config["dock"]["pinnedOnStartup"] is True,
    "dock not hover-only": config["dock"]["hoverToReveal"] is False,
    "right sidebar full height": config["sidebar"]["collapseEmptyNotifications"] is False,
    "left sidebar full height": config["sidebar"]["collapseWidgetsTab"] is False,
    "wallhaven tab": config["sidebar"]["wallhaven"]["enable"] is True,
    "news tab": config["sidebar"]["news"]["enable"] is True,
    "controls widget": config["sidebar"]["widgets"]["controls"] is True,
    "status widget": config["sidebar"]["widgets"]["status"] is True,
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit("FAIL: fresh-install defaults: " + ", ".join(failed))

schema_checks = {
    "schema settings rail": 'property string overlayStyle: "rail"' in schema,
    "schema iNiR Alt+Tab opt-in": "property bool altSwitcher: false" in schema.split(
        "property JsonObject modules: JsonObject {", 1)[1].split(
        "property JsonObject appearance: JsonObject {", 1)[0],
    "schema dock enabled": "property bool enable: true" in schema.split(
        "property JsonObject dock: JsonObject {", 1)[1].split(
        "property JsonObject controlPanel: JsonObject {", 1)[0],
    "schema dock pinned": "property bool pinnedOnStartup: true" in schema,
    "schema dock not hover-only": "property bool hoverToReveal: false" in schema,
    "schema right sidebar full height": "property bool collapseEmptyNotifications: false" in schema,
    "schema left sidebar full height": "property bool collapseWidgetsTab: false" in schema,
    "schema wallhaven tab": re.search(r"property JsonObject wallhaven: JsonObject \{[\s\S]{0,900}?property bool enable:\s*true", schema) is not None,
    "schema news tab": re.search(r"property JsonObject news: JsonObject \{[\s\S]{0,900}?property bool enable:\s*true", schema) is not None,
    "wizard applies initial profile": "root.applyProfile(root.selectedProfile)" in wizard,
    "wizard dock pinned": '"dock.pinnedOnStartup": true' in wizard,
    "wizard dock not hover-only": '"dock.hoverToReveal": false' in wizard,
    "wizard right sidebar full height": '"sidebar.collapseEmptyNotifications": false' in wizard,
    "wizard left sidebar full height": '"sidebar.collapseWidgetsTab": false' in wizard,
    "wizard preserves Waffle configuration": '"waffles.' not in wizard.split(
        "readonly property var profileEssentials", 1)[1].split(
        "// ─── Entry/exit animation state", 1)[0],
}
failed = [name for name, passed in schema_checks.items() if not passed]
if failed:
    raise SystemExit("FAIL: schema/wizard defaults: " + ", ".join(failed))

binds = (root / "defaults/niri/config.d/70-binds.kdl").read_text(encoding="utf-8")
if 'Alt+Tab { next-window; }' not in binds or 'Alt+Shift+Tab { previous-window; }' not in binds:
    raise SystemExit("FAIL: native Niri Alt+Tab bindings are missing")
if 'spawn "inir" "altSwitcher"' in binds:
    raise SystemExit("FAIL: fresh-install Alt+Tab invokes the iNiR switcher")
PY

arch_installer="$runtime_root/sdata/dist-arch/install-deps.sh"
if ! grep -Fq 'pacman -T "${depends[@]}"' "$arch_installer" \
        || ! grep -Fq 'pacman -S $installflags "${missing_deps[@]}"' "$arch_installer"; then
    printf 'FAIL: Arch PKGBUILD dependencies are not filtered through the local package database\n' >&2
    exit 1
fi
if grep -Fq 'pacman -S $installflags "${depends[@]}"' "$arch_installer"; then
    printf 'FAIL: Arch installer can still reinstall or downgrade satisfied PKGBUILD dependencies\n' >&2
    exit 1
fi

step "runtime payload manifests"
while IFS= read -r runtime_file; do
    [[ -n "$runtime_file" ]] || continue
    [[ -f "$runtime_root/$runtime_file" ]]
done < "$runtime_root/sdata/runtime-root-files.txt"

while IFS= read -r runtime_dir; do
    [[ -n "$runtime_dir" ]] || continue
    [[ -d "$runtime_root/$runtime_dir" ]]
done < "$runtime_root/sdata/runtime-payload-dirs.txt"

snapshot_lib="$runtime_root/sdata/lib/snapshots.sh"
if ! grep -Fq 'quickshell/user/desktop-items.json' "$snapshot_lib" \
        || ! grep -Fq 'desktop-items.json' "$snapshot_lib"; then
    printf 'FAIL: managed desktop items are absent from update snapshots\n' >&2
    exit 1
fi

step "canonical runtime payload"
payload_tool="$runtime_root/sdata/lib/runtime-payload.py"
payload_list="$(mktemp)"
trap 'rm -f "$payload_list"' EXIT
python3 "$payload_tool" list --root "$runtime_root" > "$payload_list"
if ! grep -qx 'assets/images/mascot/manifest.json' "$payload_list"; then
    printf 'FAIL: mascot runtime manifest is missing from canonical payload\n' >&2
    exit 1
fi
for forbidden in \
    'assets/images/mascot/frames/' \
    'assets/images/mascot/PROMPTS.md'; do
    if grep -Fq "$forbidden" "$payload_list"; then
        printf 'FAIL: canonical payload leaks local mascot artifact: %s\n' "$forbidden" >&2
        exit 1
    fi
done
if grep -Eq '^assets/images/mascot/.*\.(png|gif)$' "$payload_list"; then
    printf 'FAIL: canonical payload leaks local mascot image artifacts\n' >&2
    exit 1
fi
if ! grep -Fq 'runtime-payload.py copy' "$runtime_root/Makefile"; then
    printf 'FAIL: make install does not use the canonical runtime payload policy\n' >&2
    exit 1
fi

step "mascot pack install and repair"
bash "$runtime_root/scripts/test-mascot-pack-flow.sh"

if [[ -f "$runtime_root/Makefile" ]]; then
    step "make install dry run"
    make -n install PREFIX=/tmp/inir-stage-test -C "$runtime_root" >/dev/null
fi

if [[ -d "$runtime_root/distro/arch" ]]; then
    step "pkgbuild syntax"
    bash -n \
        "$runtime_root/distro/arch/inir-shell/PKGBUILD" \
        "$runtime_root/distro/arch/inir-shell-git/PKGBUILD" \
        "$runtime_root/distro/arch/inir-meta/PKGBUILD"

    step "version consistency"
    version="$(cat "$runtime_root/VERSION")"
    for pkg in inir-shell inir-meta; do
        pkg_ver="$(grep -m1 '^pkgver=' "$runtime_root/distro/arch/$pkg/PKGBUILD" | cut -d= -f2)"
        if [[ "$pkg_ver" != "$version" ]]; then
            printf 'FAIL: %s pkgver=%s != VERSION=%s\n' "$pkg" "$pkg_ver" "$version" >&2
            exit 1
        fi
    done
fi

step "launcher resolution"
INIR_RUNTIME_DIR="$runtime_root" bash "$launcher" path >/dev/null
INIR_RUNTIME_DIR="$runtime_root" bash "$launcher" status >/dev/null

step "application launch environment"
# XWayland is not guaranteed to own :0. Preserve live DISPLAY discovery and validation.
shell_exec="$runtime_root/modules/common/functions/ShellExec.qml"
inir_launcher="$runtime_root/scripts/inir"
if ! grep -Fq 'systemctl --user show-environment' "$shell_exec" \
        || ! grep -Fq '_manager_display="$(manager_value DISPLAY)"' "$shell_exec" \
        || ! grep -Fq 'valid_display "$DISPLAY"' "$shell_exec" \
        || ! grep -Fq 'for _x in /tmp/.X11-unix/X*' "$shell_exec"; then
    printf 'FAIL: application launches do not recover the live XWayland DISPLAY environment\n' >&2
    exit 1
fi
if ! grep -Fq 'vars_to_import+=("DISPLAY=$DISPLAY")' "$inir_launcher" \
        || ! grep -Fq 'for _xsock in /tmp/.X11-unix/X*' "$inir_launcher" \
        || ! grep -Fq 'systemctl --user set-environment "${vars_to_import[@]}"' "$inir_launcher"; then
    printf 'FAIL: session environment does not publish the XWayland DISPLAY to the user manager\n' >&2
    exit 1
fi

if command -v python3 &>/dev/null && [[ -f "$runtime_root/scripts/lib/generate-ipc-registry.py" ]]; then
    step "IPC registry freshness"
    python3 "$runtime_root/scripts/lib/generate-ipc-registry.py" --check
fi

if [[ "$run_runtime" == true ]]; then
    step "runtime restart"
    bash "$runtime_root/scripts/inir" kill >/dev/null 2>&1 || true
    sleep 1
    bash "$runtime_root/scripts/inir" run >/tmp/inir-test-local-runtime.log 2>&1 &
    sleep 3

    step "runtime logs"
    bash "$runtime_root/scripts/inir" logs

    step "runtime filtered errors"
    bash "$launcher" logs --full | grep -iE 'error|ReferenceError|TypeError|binding loop' | tail -80 || true

    step "launcher ipc"
    bash "$launcher" ipc shellUpdate diagnose >/dev/null
fi

step "runtime payload boundary"
# Validate delivered output, not duplicated implementation-specific exclude lists.
agent_names=(AGENTS.md CLAUDE.md CODEX.md PI.md codemap.md .mcp.json opencode.json skills-lock.json)
agent_dirs=(.claude .factory .opencode .codex .agents .codebase-memory .impeccable .pi-subagents)
for name in "${agent_names[@]}"; do
    if grep -Eq "(^|/)${name//./\.}$" "$payload_list"; then
        printf 'FAIL: canonical payload leaks agent artifact: %s\n' "$name" >&2
        exit 1
    fi
done
for name in "${agent_dirs[@]}"; do
    escaped="${name//./\.}"
    if grep -Eq "(^|/)${escaped}(/|$)" "$payload_list"; then
        printf 'FAIL: canonical payload leaks agent directory: %s\n' "$name" >&2
        exit 1
    fi
done
for forbidden in \
    scripts/release.sh \
    scripts/wiki-sync.sh \
    scripts/verify-docs.sh \
    scripts/qml-check.fish \
    scripts/test-local-distribution.sh \
    scripts/test-mascot-pack-flow.sh \
    scripts/test-battery-charge-limit-helper.sh \
    scripts/test-tlp-integration-lifecycle.sh \
    scripts/test-tlp-settings-ui-guards.sh \
    scripts/test-update-lifecycle.sh \
    tools/; do
    if grep -Fq "$forbidden" "$payload_list"; then
        printf 'FAIL: canonical payload leaks development tooling: %s\n' "$forbidden" >&2
        exit 1
    fi
done

for consumer in \
    "$runtime_root/Makefile" \
    "$runtime_root/distro/arch/inir-shell/PKGBUILD" \
    "$runtime_root/distro/arch/inir-shell-git/PKGBUILD" \
    "$runtime_root/nix/package.nix"; do
    [[ -f "$consumer" ]] || continue
    if ! grep -Fq 'runtime-payload.py' "$consumer"; then
        printf 'FAIL: %s bypasses canonical runtime payload policy\n' "${consumer#$runtime_root/}" >&2
        exit 1
    fi
done
rm -f "$payload_list"
trap - EXIT

printf '\nAll local distribution checks passed.\n'
