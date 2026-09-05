#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


# Battery/TLP UI test: the classic standalone page is intentionally retired.
path = Path("scripts/test-battery-charge-limit-helper.sh")
text = path.read_text(encoding="utf-8")
old = '''    assert_contains 'settingsPageName: Translation.tr("Battery")' "$classic_page" \\
        'classic Battery page must remain registered'\n    assert_contains 'pageTitle: Translation.tr("Battery")' "$waffle_page" \\
        'Waffle Battery page must remain registered'\n    assert_contains 'model: root.visibleGroups' "$classic_page" \\
        'classic page must render schema groups'\n    assert_contains 'model: root.visibleGroups' "$waffle_page" \\
        'Waffle page must render schema groups'\n    assert_contains 'onClicked: TlpSettingsService.apply()' "$classic_page" \\
        'classic page must expose explicit Apply'\n    assert_contains 'onButtonClicked: TlpSettingsService.apply()' "$waffle_page" \\
        'Waffle page must expose explicit Apply'\n'''
new = '''    assert_contains 'GeneralConfig {' "$classic_page" \\
        'legacy TLP direct links must redirect into the canonical System page'\n    assert_contains 'activeSection: "power"' "$classic_page" \\
        'legacy TLP direct links must land on System → Power'\n    assert_contains 'pageTitle: Translation.tr("Battery")' "$waffle_page" \\
        'Waffle Battery page must remain registered'\n    assert_contains 'model: root.visibleGroups' "$waffle_page" \\
        'Waffle page must render schema groups'\n    assert_contains 'onButtonClicked: TlpSettingsService.apply()' "$waffle_page" \\
        'Waffle page must expose explicit Apply'\n'''
text = replace_once(text, old, new, "retired classic TLP assertions")
path.write_text(text, encoding="utf-8")


path = Path("scripts/test-local-distribution.sh")
text = path.read_text(encoding="utf-8")
text = replace_once(text, "import pathlib\nimport sys\n", "import pathlib\nimport re\nimport sys\n", "python imports")
text = replace_once(
    text,
    '    "schema wallhaven tab": "property JsonObject wallhaven: JsonObject {\\n                    // Enable/disable the Wallhaven tab in the left sidebar\\n                    property bool enable: true" in schema,\n    "schema news tab": "property JsonObject news: JsonObject {\\n                    property bool enable: true" in schema,\n',
    '    "schema wallhaven tab": re.search(r"property JsonObject wallhaven: JsonObject \\{[\\s\\S]{0,900}?property bool enable:\\s*true", schema) is not None,\n    "schema news tab": re.search(r"property JsonObject news: JsonObject \\{[\\s\\S]{0,900}?property bool enable:\\s*true", schema) is not None,\n',
    "schema formatting-independent checks",
)

mascot_start = text.index('step "mascot runtime manifest"')
mascot_end = text.index('step "mascot pack install and repair"', mascot_start)
mascot = '''step "canonical runtime payload"\npayload_tool="$runtime_root/sdata/lib/runtime-payload.py"\npayload_list="$(mktemp)"\ntrap 'rm -f "$payload_list"' EXIT\npython3 "$payload_tool" list --root "$runtime_root" > "$payload_list"\nif ! grep -qx 'assets/images/mascot/manifest.json' "$payload_list"; then\n    printf 'FAIL: mascot runtime manifest is missing from canonical payload\\n' >&2\n    exit 1\nfi\nfor forbidden in \\
    'assets/images/mascot/frames/' \\
    'assets/images/mascot/PROMPTS.md'; do\n    if grep -Fq "$forbidden" "$payload_list"; then\n        printf 'FAIL: canonical payload leaks local mascot artifact: %s\\n' "$forbidden" >&2\n        exit 1\n    fi\ndone\nif grep -Eq '^assets/images/mascot/.*\\.(png|gif)$' "$payload_list"; then\n    printf 'FAIL: canonical payload leaks local mascot image artifacts\\n' >&2\n    exit 1\nfi\nif ! grep -Fq 'runtime-payload.py copy' "$runtime_root/Makefile"; then\n    printf 'FAIL: make install does not use the canonical runtime payload policy\\n' >&2\n    exit 1\nfi\n\n'''
text = text[:mascot_start] + mascot + text[mascot_end:]

leak_start = text.index('step "agent artifact leak guard"')
leak_end = text.index("printf '\\nAll local distribution checks passed.\\n'", leak_start)
leak = '''step "runtime payload boundary"\n# Validate delivered output, not duplicated implementation-specific exclude lists.\nagent_names=(AGENTS.md CLAUDE.md CODEX.md PI.md codemap.md .mcp.json opencode.json skills-lock.json)\nagent_dirs=(.claude .factory .opencode .codex .agents .codebase-memory .impeccable .pi-subagents)\nfor name in "${agent_names[@]}"; do\n    if grep -Eq "(^|/)${name//./\\.}$" "$payload_list"; then\n        printf 'FAIL: canonical payload leaks agent artifact: %s\\n' "$name" >&2\n        exit 1\n    fi\ndone\nfor name in "${agent_dirs[@]}"; do\n    escaped="${name//./\\.}"\n    if grep -Eq "(^|/)${escaped}(/|$)" "$payload_list"; then\n        printf 'FAIL: canonical payload leaks agent directory: %s\\n' "$name" >&2\n        exit 1\n    fi\ndone\nfor forbidden in \\
    scripts/release.sh \\
    scripts/wiki-sync.sh \\
    scripts/verify-docs.sh \\
    scripts/qml-check.fish \\
    scripts/test-local-distribution.sh \\
    scripts/test-mascot-pack-flow.sh \\
    scripts/test-battery-charge-limit-helper.sh \\
    scripts/test-tlp-integration-lifecycle.sh \\
    scripts/test-tlp-settings-ui-guards.sh \\
    scripts/test-update-lifecycle.sh \\
    tools/; do\n    if grep -Fq "$forbidden" "$payload_list"; then\n        printf 'FAIL: canonical payload leaks development tooling: %s\\n' "$forbidden" >&2\n        exit 1\n    fi\ndone\n\nfor consumer in \\
    "$runtime_root/Makefile" \\
    "$runtime_root/distro/arch/inir-shell/PKGBUILD" \\
    "$runtime_root/distro/arch/inir-shell-git/PKGBUILD" \\
    "$runtime_root/nix/package.nix"; do\n    [[ -f "$consumer" ]] || continue\n    if ! grep -Fq 'runtime-payload.py' "$consumer"; then\n        printf 'FAIL: %s bypasses canonical runtime payload policy\\n' "${consumer#$runtime_root/}" >&2\n        exit 1\n    fi\ndone\nrm -f "$payload_list"\ntrap - EXIT\n\n'''
text = text[:leak_start] + leak + text[leak_end:]
path.write_text(text, encoding="utf-8")

print("test contracts refreshed")
