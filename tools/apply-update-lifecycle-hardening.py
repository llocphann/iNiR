#!/usr/bin/env python3
from pathlib import Path


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# sdata/lib/functions.sh — one canonical payload exclusion policy
# ---------------------------------------------------------------------------
path = "sdata/lib/functions.sh"
text = read(path)
start_marker = "# Never distributed. The payload is copied one directory at a time"
start = text.index(start_marker)
end = text.index("function install_file(){", start)
payload_block = r'''# Generate rsync exclusions from the same policy used by package delivery and manifests.
# Resolve relative paths against the source checkout, not the copied directory's basename.
INIR_PAYLOAD_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime-payload.py"
_runtime_rsync() {
  local source_path payload_root relative filters
  source_path="$(realpath -e -- "$1")" || return
  payload_root="$(cd "$(dirname "$INIR_PAYLOAD_TOOL")/../.." && pwd)" || return
  relative="${source_path#"$payload_root"/}"
  [[ "$relative" != "$source_path" ]] || { echo "Install source is outside repository" >&2; return 1; }
  filters="$(python3 "$INIR_PAYLOAD_TOOL" filters --root "$payload_root" --subdir "$relative")" || return
  local -a exclusions
  mapfile -t exclusions <<< "$filters"
  local target="$2"
  shift 2
  rsync -a "${exclusions[@]}" "$@" "$source_path/" "$target/"
}

rsync_dir() (
  set -o pipefail
  x mkdir -p "$2"
  local dest
  dest="$(realpath -se -- "$2")" || return
  x mkdir -p "$(dirname "${INSTALLED_LISTFILE}")"
  _runtime_rsync "$1" "$2" --out-format='%i %n' | awk -v d="$dest" '$1 ~ /^>/{ sub(/^[^ ]+ /,""); printf d "/" $0 "\n" }' >> "${INSTALLED_LISTFILE}"
)

rsync_dir__sync() (
  set -o pipefail
  x mkdir -p "$2"
  local dest
  dest="$(realpath -se -- "$2")" || return
  x mkdir -p "$(dirname "${INSTALLED_LISTFILE}")"
  _runtime_rsync "$1" "$2" --delete --out-format='%i %n' | awk -v d="$dest" '$1 ~ /^>/{ sub(/^[^ ]+ /,""); printf d "/" $0 "\n" }' >> "${INSTALLED_LISTFILE}"
)

'''
text = text[:start] + payload_block + text[end:]
write(path, text)


# ---------------------------------------------------------------------------
# sdata/lib/robust-update.sh — deterministic manifests and fail-closed verifier
# ---------------------------------------------------------------------------
path = "sdata/lib/robust-update.sh"
text = read(path)
start = text.index("generate_manifest() {")
end = text.index("# Get list of files", start)
generate_manifest = r'''generate_manifest() {
    local repo_root="$1"
    local manifest_file="$2"
    local commit
    commit=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local entries
    entries=$(mktemp) || return 1
    if ! python3 "$repo_root/sdata/lib/runtime-payload.py" manifest --root "$repo_root" > "$entries"; then
        rm -f "$entries"
        return 1
    fi
    {
        echo "# inir-manifest v2"
        echo "# generated: $(date -Iseconds)"
        echo "# commit: $commit"
        cat "$entries"
    } > "$manifest_file"
    local result=$?
    rm -f "$entries"
    return "$result"
}

'''
text = text[:start] + generate_manifest + text[end:]

start = text.index("get_orphan_files() {")
end = text.index("#####################################################################################\n# Backup & Rollback", start)
get_orphans = r'''get_orphan_files() {
    local target_dir="$1"
    local manifest_file="$2"
    local runtime_root_manifest="${REPO_ROOT}/sdata/runtime-root-files.txt"
    local runtime_dirs_manifest="${REPO_ROOT}/sdata/runtime-payload-dirs.txt"

    [[ -f "$manifest_file" ]] || return 0

    local current_files
    current_files=$(mktemp) || return 1

    if ! (
      set -o pipefail
      {
        find "$target_dir" -maxdepth 1 -name "*.qml" -type f -printf "%f\n" 2>/dev/null

        if [[ -f "$runtime_root_manifest" ]]; then
            while IFS= read -r runtime_file; do
                [[ -n "$runtime_file" ]] || continue
                [[ -f "$target_dir/$runtime_file" ]] && echo "$runtime_file"
            done < "$runtime_root_manifest"
        fi

        if [[ -f "$runtime_dirs_manifest" ]]; then
            while IFS= read -r dir; do
                [[ -n "$dir" ]] || continue
                if [[ -d "$target_dir/$dir" ]]; then
                    find "$target_dir/$dir" -type f ! -name 'AGENTS.md' -printf "$dir/%P\n" 2>/dev/null
                fi
            done < "$runtime_dirs_manifest"
        fi
      } | python3 "$REPO_ROOT/sdata/lib/runtime-payload.py" filter-installed --root "$REPO_ROOT" | sort -u > "$current_files"
    ); then
        rm -f "$current_files"
        return 1
    fi

    local manifest_paths
    manifest_paths=$(mktemp) || { rm -f "$current_files"; return 1; }
    grep -v "^#" "$manifest_file" | cut -d: -f1 | sort -u > "$manifest_paths"
    comm -23 "$current_files" "$manifest_paths"
    local result=$?
    rm -f "$current_files" "$manifest_paths"
    return "$result"
}

'''
text = text[:start] + get_orphans + text[end:]

start = text.index("verify_qs_loads() {")
end = text.index("# Full verification suite", start)
verify_qs = r'''verify_qs_loads() {
    local timeout_sec="${1:-$VERIFICATION_TIMEOUT}"
    local target="${2:-$II_TARGET}"

    if [[ ! -f "$target/shell.qml" ]]; then
        log_error "Quickshell verification target is missing shell.qml: $target"
        return 1
    fi
    if ! command -v qs >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        log_error "Quickshell verification requires qs and timeout"
        return 1
    fi

    # Probe with an isolated instance. Do not kill the currently running shell:
    # update verification must never destroy the known-good instance first.
    local output=""
    local exit_code=0
    output=$(timeout "$timeout_sec" qs -n -p "$target" 2>&1) || exit_code=$?

    local fatal_output=""
    fatal_output=$(printf '%s\n' "$output" \
        | grep -E 'QQmlApplicationEngine failed|SyntaxError|ReferenceError|TypeError|Type .* unavailable|module .* is not installed|^[[:space:]]*(ERROR|FATAL|error:|Error:)' \
        | grep -Eiv 'polkit|bluez' || true)
    if [[ -n "$fatal_output" ]]; then
        log_error "Quickshell failed to load properly"
        printf '%s\n' "$fatal_output" | head -8
        return 1
    fi

    # shell.qml emits this immediately from Component.onCompleted. The older
    # Configuration Loaded marker is retained for compatibility with older payloads.
    if printf '%s\n' "$output" | grep -Fq 'Component.onCompleted (shell.qml ready)' \
            || printf '%s\n' "$output" | grep -Fq 'Configuration Loaded'; then
        return 0
    fi

    if [[ "$exit_code" -eq 124 ]]; then
        log_error "Quickshell probe timed out before the shell startup marker"
    elif [[ "$exit_code" -ne 0 ]]; then
        log_error "Quickshell probe exited with status $exit_code before startup completed"
    else
        log_error "Quickshell probe exited without a shell startup marker"
    fi
    [[ -n "$output" ]] && printf '%s\n' "$output" | tail -12 >&2
    return 1
}

'''
text = text[:start] + verify_qs + text[end:]

start = text.index("run_verification() {")
end = text.index("#####################################################################################\n# Orphan Cleanup", start)
run_verification = r'''run_verification() {
    local mode="${1:-runtime}"
    local errors=0

    log_info "Running post-update verification..."

    if [[ ! -f "$II_MANIFEST_FILE" ]]; then
        log_error "Manifest file missing: $II_MANIFEST_FILE"
        ((errors++))
    fi

    local critical_files=("shell.qml" "GlobalStates.qml" "modules/common/Config.qml")
    for file in "${critical_files[@]}"; do
        if [[ ! -f "$II_TARGET/$file" ]]; then
            log_error "Critical file missing: $file"
            ((errors++))
        fi
    done

    if [[ -d "$II_TARGET/scripts" ]]; then
        local scripts_without_exec
        scripts_without_exec=$(find "$II_TARGET/scripts" -type f \( -name "*.sh" -o -name "*.fish" -o -name "*.py" \) ! -executable 2>/dev/null || true)
        if [[ -n "$scripts_without_exec" ]]; then
            log_warning "Fixing script permissions..."
            find "$II_TARGET/scripts" -type f \( -name "*.sh" -o -name "*.fish" -o -name "*.py" \) -exec chmod +x {} \; 2>/dev/null || true
        fi
    fi

    # Run repository-wide syntax/startup guards when fish is available. The
    # checker uses qmlformat when installed and still runs critical guards without it.
    if command -v fish >/dev/null 2>&1 && [[ -f "${REPO_ROOT}/scripts/qml-check.fish" ]]; then
        if ! fish "${REPO_ROOT}/scripts/qml-check.fish" --all --root "$II_TARGET"; then
            log_error "QML static verification failed"
            ((errors++))
        fi
    fi

    if [[ "$mode" != "static" && $errors -eq 0 ]]; then
        if ! verify_qs_loads; then
            log_error "Quickshell runtime verification failed"
            ((errors++))
        else
            log_success "Quickshell loads correctly"
        fi
    fi

    return "$errors"
}

'''
text = text[:start] + run_verification + text[end:]

# Make orphan cleanup propagate payload/filter errors.
text = replace_once(
    text,
    '    local orphans\n    orphans=$(get_orphan_files "$target_dir" "$manifest_file")\n',
    '    local orphans\n    orphans=$(get_orphan_files "$target_dir" "$manifest_file") || return 1\n',
    "robust-update orphan propagation",
)
write(path, text)


# ---------------------------------------------------------------------------
# setup — migrations, payload sync, launcher topology, verified restart/status
# ---------------------------------------------------------------------------
path = "setup"
text = read(path)

old_progress = r'''_report_progress() {
    local step="$1" msg="$2"
    echo "progress:${step}:${_update_total_steps}:${msg}" > "$_update_status_file" 2>/dev/null || true
}
'''
new_progress = r'''_write_update_status() {
    local status="$1"
    local status_dir
    status_dir="$(dirname "$_update_status_file")"
    mkdir -p "$status_dir" 2>/dev/null || return 0
    printf '%s\n' "$status" > "$_update_status_file" 2>/dev/null || true
}

_report_progress() {
    local step="$1" msg="$2"
    _write_update_status "progress:${step}:${_update_total_steps}:${msg}"
}

_report_update_failure() {
    local code="$1" msg="$2"
    _write_update_status "failed:${code}:${msg}"
}
'''
text = replace_once(text, old_progress, new_progress, "setup progress writer")

helper_marker = "repair_update_owned_state() {"
helper_pos = text.index(helper_marker)
helpers = r'''inir_supported_session_active() {
    # Never use WAYLAND_DISPLAY as a compositor detector: KDE/GNOME set it too.
    [[ -n "${NIRI_SOCKET:-}" ]] && return 0
    pgrep -x niri >/dev/null 2>&1 && return 0
    [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && return 0
    pgrep -x Hyprland >/dev/null 2>&1
}

restart_updated_shell() {
    local runtime_dir="$1"
    local launcher=""

    if [[ -x "${XDG_BIN_HOME}/inir" ]]; then
        launcher="${XDG_BIN_HOME}/inir"
    elif [[ -x "${REPO_ROOT}/scripts/inir" ]]; then
        launcher="${REPO_ROOT}/scripts/inir"
    elif [[ -x "${runtime_dir}/scripts/inir" ]]; then
        launcher="${runtime_dir}/scripts/inir"
    else
        log_error "No iNiR launcher available for verified restart"
        return 1
    fi

    INIR_RUNTIME_DIR="$runtime_dir" "$launcher" restart -q -c "$runtime_dir"
}

'''
text = text[:helper_pos] + helpers + text[helper_pos:]

# Package-managed restart gate must name a supported compositor explicitly.
text = text.replace(
    'if [[ -n "${NIRI_SOCKET:-}" ]] || pgrep -x niri &>/dev/null || pgrep -x Hyprland &>/dev/null; then',
    'if inir_supported_session_active; then',
)

# Required migrations must run even when git and installed version already match.
branch_start = text.index('        elif [[ "$installed_commit" == "$repo_commit" ]]; then')
branch_end = text.index('        else\n            # Local repo ahead of installed - create snapshot', branch_start)
already_block = r'''        elif [[ "$installed_commit" == "$repo_commit" ]]; then
            tui_success "Already up to date ($installed_ver)"

            local pending=$(count_pending_migrations 2>/dev/null || echo "0")
            if [[ "$pending" -gt 0 ]]; then
                echo ""
                if ! run_migrations_auto; then
                    _report_update_failure "migration" "Required migration failed"
                    tui_error "Required migration failed"
                    return 1
                fi
                pending=$(count_pending_migrations 2>/dev/null || echo "0")
                if [[ "$pending" -gt 0 ]]; then
                    tui_warn "$pending optional migration(s) available"
                    if $ask && tui_confirm "Review and apply now?"; then
                        run_migrations_interactive
                    fi
                fi
            fi

            if ! sync_launcher_from_repo >/dev/null; then
                _report_update_failure "launcher" "Launcher refresh failed"
                tui_error "Could not refresh the iNiR launcher"
                return 1
            fi
            sync_user_inir_service_from_repo_if_present >/dev/null 2>&1 || true
            ensure_user_inir_service_enabled >/dev/null 2>&1 || true
            _write_update_status "success"
            return 0
'''
text = text[:branch_start] + already_block + text[branch_end:]

# Create a repo-copy runtime backup immediately before destructive payload sync.
real_paths = r'''    local src_real=$(realpath "$II_SOURCE" 2>/dev/null || echo "$II_SOURCE")
    local tgt_real=$(realpath "$II_TARGET" 2>/dev/null || echo "$II_TARGET")
'''
backup_paths = real_paths + r'''
    local runtime_backup_path=""
    if [[ "$src_real" != "$tgt_real" && -f "${II_TARGET}/shell.qml" ]]; then
        runtime_backup_path=$(create_update_backup "$II_TARGET" 2>/dev/null || true)
        if [[ -z "$runtime_backup_path" ]]; then
            _report_update_failure "backup" "Runtime backup failed"
            tui_error "Could not create the pre-update runtime backup"
            return 1
        fi
    fi
'''
text = replace_once(text, real_paths, backup_paths, "setup runtime backup")

old_sync = '                [[ -d "${II_SOURCE}/${dir}" ]] && mkdir -p "${II_TARGET}/${dir}" && rsync -a --delete --exclude=\'AGENTS.md\' "${II_SOURCE}/${dir}/" "${II_TARGET}/${dir}/"\n'
new_sync = r'''                if [[ -d "${II_SOURCE}/${dir}" ]]; then
                    mkdir -p "${II_TARGET}/${dir}"
                    if ! python3 "${II_SOURCE}/sdata/lib/runtime-payload.py" sync-dir \
                            --root "$II_SOURCE" --subdir "$dir" \
                            --target "${II_TARGET}/${dir}" --delete; then
                        _report_update_failure "payload" "Runtime payload sync failed"
                        [[ -n "$runtime_backup_path" ]] && rollback_update >/dev/null 2>&1 || true
                        tui_error "Runtime payload sync failed"
                        return 1
                    fi
                fi
'''
text = replace_once(text, old_sync, new_sync, "setup payload rsync")

old_manifest = r'''    # Generate manifest
    generate_manifest "$II_SOURCE" "${II_TARGET}/.inir-manifest"

    # Remove orphan files left from previous versions
    cleanup_orphans "$II_TARGET" "${II_TARGET}/.inir-manifest"
'''
new_manifest = r'''    # Generate the installed manifest from the same policy used to copy files.
    if ! generate_manifest "$II_SOURCE" "${II_TARGET}/.inir-manifest"; then
        _report_update_failure "manifest" "Runtime manifest generation failed"
        [[ -n "$runtime_backup_path" ]] && rollback_update >/dev/null 2>&1 || true
        tui_error "Runtime manifest generation failed"
        return 1
    fi

    # Remove managed source-only files left by older updater implementations.
    if ! cleanup_orphans "$II_TARGET" "${II_TARGET}/.inir-manifest"; then
        _report_update_failure "cleanup" "Runtime orphan cleanup failed"
        [[ -n "$runtime_backup_path" ]] && rollback_update >/dev/null 2>&1 || true
        tui_error "Runtime orphan cleanup failed"
        return 1
    fi
'''
text = replace_once(text, old_manifest, new_manifest, "setup manifest cleanup")

launcher_start = text.index('    local launcher_target="${XDG_BIN_HOME}/inir"', branch_end)
launcher_end = text.index('    local _service_refresh_status=1', launcher_start)
launcher_block = r'''    local launcher_target="${XDG_BIN_HOME}/inir"
    if [[ -f "${REPO_ROOT}/scripts/inir" ]]; then
        if ! sync_launcher_from_repo >/dev/null; then
            _report_update_failure "launcher" "Launcher refresh failed"
            [[ -n "$runtime_backup_path" ]] && rollback_update >/dev/null 2>&1 || true
            tui_error "Could not refresh the iNiR launcher"
            return 1
        fi
        ensure_launcher_path_in_shells "$XDG_BIN_HOME"
        if ! command -v inir &>/dev/null && [[ ":$PATH:" != *":${XDG_BIN_HOME}:"* ]]; then
            tui_warn "Launcher installed to ${launcher_target}, but ${XDG_BIN_HOME} is not in PATH for this shell"
        fi
    fi

'''
text = text[:launcher_start] + launcher_block + text[launcher_end:]

# Do not claim the new installed version before verification and restart succeed.
version_start = text.index('    # Update version\n', launcher_start)
version_end = text.index('    tui_success "Files synced"\n', version_start)
text = text[:version_start] + text[version_end:]

# Replace asynchronous success/restart tail with a synchronous verified lifecycle.
tail_start = text.index('    # Signal success to the shell UI before restart')
tail_end = text.index('\n}\n\n###############################################################################\n# Doctor', tail_start)
new_tail = r'''    # Validate the installed payload before touching the live shell. This catches
    # parser/startup-critical problems even when there is no graphical session.
    if ! run_verification static; then
        _report_update_failure "verification" "Static verification failed"
        if [[ -n "$runtime_backup_path" ]]; then
            rollback_update >/dev/null 2>&1 || true
        fi
        tui_error "Update verification failed; the previous repo-copy runtime was restored when possible"
        return 1
    fi

    # Restart only in an explicitly supported compositor session. The launcher
    # owns the systemd/direct-process lifecycle and waits for the new shell.
    if inir_supported_session_active; then
        _step_phase_start 7 "Restarting shell"
        if ! restart_updated_shell "$II_TARGET"; then
            _step_phase_fail "Shell failed to restart"
            _report_update_failure "restart" "Shell failed to restart"
            if [[ -n "$runtime_backup_path" ]]; then
                tui_warn "Restoring the previous runtime payload..."
                if rollback_update >/dev/null 2>&1; then
                    restart_updated_shell "$II_TARGET" >/dev/null 2>&1 || true
                fi
            fi
            tui_error "The updated shell did not start successfully"
            tui_info "Run './setup rollback' if this is a repo-link checkout."
            return 1
        fi
        _step_phase_done "Shell restarted and verified"
    else
        _step_phase_header 7 "Restarting shell"
        _step_phase_skip "No active Niri/Hyprland session; restart deferred"
        tui_info "The shell will use the new files on the next supported compositor session"
    fi

    # Commit version metadata only after migrations, validation and live restart
    # (when applicable) have succeeded.
    set_installed_version "$repo_ver" "$repo_commit" "update"
    if [[ -d "$II_TARGET" && "$src_real" != "$tgt_real" ]]; then
        write_version_info_json "${II_TARGET}/version.json" "$repo_ver" "$repo_commit" "setup-update"
    fi

    cleanup_old_backups "$II_BACKUP_DIR" 5
    _write_update_status "success"

    echo ""
    tui_alert "success" "Update complete" "Version $repo_ver ($repo_commit) synced and verified.\nRun './setup rollback' if something breaks."
'''
text = text[:tail_start] + new_tail + text[tail_end:]

# Remaining direct success markers in update flows use the safe helper.
text = text.replace('echo "success" > "$_update_status_file" 2>/dev/null || true', '_write_update_status "success"')
write(path, text)


# ---------------------------------------------------------------------------
# snapshots.sh — restore via the same launcher/systemd lifecycle
# ---------------------------------------------------------------------------
path = "sdata/lib/snapshots.sh"
text = read(path)
old_stop = r'''    # Stop shell
    local runtime_target="${XDG_CONFIG_HOME}/quickshell/inir"
    qs -p "$runtime_target" kill &>/dev/null || true
'''
new_stop = r'''    # Stop the shell through its lifecycle owner before replacing files.
    local runtime_target="${XDG_CONFIG_HOME}/quickshell/inir"
    local runtime_launcher=""
    if command -v inir >/dev/null 2>&1; then
        runtime_launcher="$(command -v inir)"
    elif [[ -x "${runtime_target}/scripts/inir" ]]; then
        runtime_launcher="${runtime_target}/scripts/inir"
    fi
    if [[ -n "$runtime_launcher" ]]; then
        INIR_RUNTIME_DIR="$runtime_target" "$runtime_launcher" kill -c "$runtime_target" >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop inir.service >/dev/null 2>&1 || true
    fi
'''
text = replace_once(text, old_stop, new_stop, "snapshot stop lifecycle")

restart_start = text.index('    # Restart shell (only if we have access to the session)')
restart_end = text.index('\n}\n\n###############################################################################\n# Interactive rollback', restart_start)
new_restart = r'''    # Refresh launcher/service topology after the checkout moved backwards.
    declare -F sync_launcher_from_repo >/dev/null 2>&1 && sync_launcher_from_repo >/dev/null 2>&1 || true
    declare -F sync_user_inir_service_from_repo_if_present >/dev/null 2>&1 \
        && sync_user_inir_service_from_repo_if_present >/dev/null 2>&1 || true
    declare -F ensure_user_inir_service_enabled >/dev/null 2>&1 \
        && ensure_user_inir_service_enabled >/dev/null 2>&1 || true

    local session_active=false
    if declare -F inir_supported_session_active >/dev/null 2>&1; then
        inir_supported_session_active && session_active=true
    elif [[ -n "${NIRI_SOCKET:-}" ]] || pgrep -x niri >/dev/null 2>&1 \
            || [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || pgrep -x Hyprland >/dev/null 2>&1; then
        session_active=true
    fi

    if $session_active; then
        log_info "Starting shell through the iNiR lifecycle..."
        if declare -F restart_updated_shell >/dev/null 2>&1; then
            if ! restart_updated_shell "$runtime_target"; then
                log_error "Snapshot restored but shell restart failed"
                return 1
            fi
        else
            local restored_launcher=""
            command -v inir >/dev/null 2>&1 && restored_launcher="$(command -v inir)"
            [[ -z "$restored_launcher" && -x "${runtime_target}/scripts/inir" ]] \
                && restored_launcher="${runtime_target}/scripts/inir"
            if [[ -z "$restored_launcher" ]] \
                    || ! INIR_RUNTIME_DIR="$runtime_target" "$restored_launcher" restart -q -c "$runtime_target"; then
                log_error "Snapshot restored but no verified launcher restart was available"
                return 1
            fi
        fi
        tui_success "Snapshot restored and shell restarted"
    else
        tui_warn "No supported compositor session - shell restart skipped"
        tui_info "Run: inir restart (from your Niri/Hyprland session)"
        tui_success "Snapshot restored"
    fi
'''
text = text[:restart_start] + new_restart + text[restart_end:]
write(path, text)


# ---------------------------------------------------------------------------
# Aggregate tests — make fork-specific guards part of the default test command
# ---------------------------------------------------------------------------
path = "scripts/test-local-distribution.sh"
text = read(path)
text = replace_once(
    text,
    '    "$runtime_root/scripts/test-tlp-integration-lifecycle.sh" \\\n',
    '    "$runtime_root/scripts/test-tlp-integration-lifecycle.sh" \\\n    "$runtime_root/scripts/test-tlp-settings-ui-guards.sh" \\\n    "$runtime_root/scripts/test-update-lifecycle.sh" \\\n',
    "aggregate bash syntax list",
)
text = replace_once(
    text,
    'step "TLP integration lifecycle"\nbash "$runtime_root/scripts/test-tlp-integration-lifecycle.sh"\n\nstep "session tray ordering"',
    'step "TLP integration lifecycle"\nbash "$runtime_root/scripts/test-tlp-integration-lifecycle.sh"\n\nstep "TLP settings UI guards"\nbash "$runtime_root/scripts/test-tlp-settings-ui-guards.sh"\n\nstep "update lifecycle regression"\nbash "$runtime_root/scripts/test-update-lifecycle.sh"\n\nstep "session tray ordering"',
    "aggregate fork regression calls",
)
write(path, text)

print("update lifecycle hardening applied")
