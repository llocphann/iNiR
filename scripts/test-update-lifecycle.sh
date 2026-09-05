#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

setup_file="$repo_root/setup"
robust="$repo_root/sdata/lib/robust-update.sh"
snapshots="$repo_root/sdata/lib/snapshots.sh"
payload_tool="$repo_root/sdata/lib/runtime-payload.py"

for required in "$setup_file" "$robust" "$snapshots" "$payload_tool"; do
    [[ -f "$required" ]] || fail "missing lifecycle file: ${required#$repo_root/}"
done

# The generic Wayland variable must never be used as the update/rollback
# compositor gate; KDE and GNOME export it too.
if grep -Fq '[[ -n "$NIRI_SOCKET" ]] || [[ -n "$WAYLAND_DISPLAY" ]]' "$setup_file"; then
    fail 'setup still treats WAYLAND_DISPLAY as a supported compositor gate'
fi
if grep -Fq '[[ -n "$NIRI_SOCKET" ]] || [[ -n "$WAYLAND_DISPLAY" ]]' "$snapshots"; then
    fail 'snapshot restore still treats WAYLAND_DISPLAY as a supported compositor gate'
fi

# Restart and rollback must go through the lifecycle owner, never fire-and-forget.
if grep -Fq 'nohup systemctl --user restart inir.service' "$setup_file" \
        || grep -Fq 'nohup qs -p "${II_TARGET}"' "$setup_file"; then
    fail 'setup update still performs an asynchronous unverified restart'
fi
if grep -Fq 'nohup qs -p "$runtime_target"' "$snapshots"; then
    fail 'snapshot restore still starts an unsupervised Quickshell instance'
fi

grep -Fq 'restart_updated_shell "$II_TARGET"' "$setup_file" \
    || fail 'setup update does not use the verified launcher restart helper'
grep -Fq 'sync_launcher_from_repo' "$setup_file" \
    || fail 'setup update does not preserve repo-link launcher topology'
grep -Fq 'runtime-payload.py" sync-dir' "$setup_file" \
    || fail 'setup update does not use the canonical runtime payload policy'

# Inspect the exact already-up-to-date and completion ordering rather than just
# grepping for functions that may occur in unrelated commands.
python3 - "$setup_file" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
marker = 'elif [[ "$installed_commit" == "$repo_commit" ]]; then'
if marker not in text:
    raise SystemExit('missing already-up-to-date branch')
block = text.split(marker, 1)[1].split('# Local repo ahead of installed - create snapshot', 1)[0]
if 'run_migrations_auto' not in block:
    raise SystemExit('required migrations are not applied in already-up-to-date branch')
if '_write_update_status "success"' not in block:
    raise SystemExit('already-up-to-date branch has no terminal success marker')
if block.index('run_migrations_auto') > block.index('_write_update_status "success"'):
    raise SystemExit('success is written before required migrations')

run = text.split('run_update() {', 1)[1].split('\n###############################################################################\n# Doctor', 1)[0]
restart = run.rfind('restart_updated_shell "$II_TARGET"')
version = run.rfind('set_installed_version "$repo_ver" "$repo_commit" "update"')
success = run.rfind('_write_update_status "success"')
if restart < 0 or version < restart or success < version:
    raise SystemExit('update completion ordering must be restart -> version metadata -> success')
PY

# Runtime payload manifest must exclude source-only tests/tooling while retaining
# actual launch/runtime files. This prevents install/update payload drift.
python3 "$payload_tool" manifest --root "$repo_root" > "$tmp/manifest"
grep -q '^shell.qml:' "$tmp/manifest" || fail 'runtime manifest is missing shell.qml'
grep -q '^scripts/inir:' "$tmp/manifest" || fail 'runtime manifest is missing scripts/inir'
for excluded in \
    scripts/qml-check.fish \
    scripts/test-local-distribution.sh \
    scripts/test-battery-charge-limit-helper.sh \
    scripts/test-tlp-integration-lifecycle.sh \
    scripts/test-tlp-settings-ui-guards.sh \
    scripts/test-update-lifecycle.sh; do
    if grep -q "^${excluded}:" "$tmp/manifest"; then
        fail "source-only file leaked into runtime manifest: $excluded"
    fi
done

# Exercise the verifier with a fake qs process. A fatal startup must fail, a
# startup marker followed by a long-running shell succeeds, and a silent hang
# must fail rather than being treated as healthy.
mkdir -p "$tmp/bin" "$tmp/xdg/quickshell/inir" "$tmp/state"
printf '%s\n' '// probe shell' > "$tmp/xdg/quickshell/inir/shell.qml"
cat > "$tmp/bin/qs" <<'EOF_QS'
#!/usr/bin/env bash
case "${MOCK_QS_MODE:-fatal}" in
    fatal)
        printf '%s\n' 'Error: Type MissingSingleton unavailable'
        exit 1
        ;;
    boot)
        printf '%s\n' '[Boot] T+0ms: Component.onCompleted (shell.qml ready)'
        sleep 5
        ;;
    silent)
        sleep 5
        ;;
    *) exit 2 ;;
esac
EOF_QS
chmod +x "$tmp/bin/qs"

export PATH="$tmp/bin:$PATH"
export XDG_CONFIG_HOME="$tmp/xdg"
export XDG_STATE_HOME="$tmp/state"
export REPO_ROOT="$repo_root"
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
# shellcheck disable=SC1090
source "$robust"

export MOCK_QS_MODE=fatal
if verify_qs_loads 1 "$tmp/xdg/quickshell/inir" >/dev/null 2>&1; then
    fail 'fatal Quickshell probe was accepted'
fi

export MOCK_QS_MODE=boot
if ! verify_qs_loads 1 "$tmp/xdg/quickshell/inir" >/dev/null 2>&1; then
    fail 'healthy startup marker was rejected'
fi

export MOCK_QS_MODE=silent
if verify_qs_loads 1 "$tmp/xdg/quickshell/inir" >/dev/null 2>&1; then
    fail 'silent Quickshell timeout was accepted'
fi

printf '%s\n' '1..1'
printf '%s\n' 'ok 1 - updater lifecycle is fail-closed and payload policy is consistent'
