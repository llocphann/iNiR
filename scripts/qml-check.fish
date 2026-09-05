#!/usr/bin/env fish
# QML validation for iNiR. Syntax/startup-critical failures are fatal;
# style heuristics remain warnings so existing code is not blocked.

set -l project_root (realpath (dirname (status filename))/..)
set -l scan_root $project_root
set -l scan_all 0
set -l positional

set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case --all
            set scan_all 1
        case --root
            set i (math $i + 1)
            if test $i -gt (count $argv)
                echo "qml-check: --root requires a path" >&2
                exit 2
            end
            set scan_root (realpath $argv[$i])
        case '*'
            set -a positional $argv[$i]
    end
    set i (math $i + 1)
end

if not test -d $scan_root
    echo "qml-check: root not found: $scan_root" >&2
    exit 2
end

set -l parser ""
for candidate in qmlformat qmlformat6 /usr/lib/qt6/bin/qmlformat /usr/lib/x86_64-linux-gnu/qt6/bin/qmlformat
    if string match -q '/*' $candidate
        if test -x $candidate
            set parser $candidate
            break
        end
    else if type -q $candidate
        set parser $candidate
        break
    end
end

set -l qml_files
if test (count $positional) -gt 0
    for file in $positional
        if test -f $file
            set -a qml_files (realpath $file)
        else if test -f $scan_root/$file
            set -a qml_files (realpath $scan_root/$file)
        else
            echo "qml-check: file not found: $file" >&2
            exit 2
        end
    end
else if test $scan_all -eq 1
    set qml_files (find $scan_root -type f -name '*.qml' \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' | sort)
else
    set qml_files (find $scan_root -type f -name '*.qml' -mmin -5 \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' | head -10)
end

if test (count $qml_files) -eq 0
    exit 0
end

set -l fatal_errors 0
set -l warnings 0

for file in $qml_files
    set -l basename (string replace "$scan_root/" "" $file)

    # qmlformat parses QML before formatting. Writing to stdout makes this a
    # non-mutating syntax check and catches missing braces/tokens early.
    if test -n "$parser"
        if not $parser $file >/dev/null 2>&1
            echo "ERROR: $basename: QML parser rejected the file" >&2
            set fatal_errors (math $fatal_errors + 1)
        end
    end

    # Quickshell's Singleton type is not a QtQuick type. Accept both modern
    # semicolon-free imports and the older `import Quickshell;` spelling.
    if grep -qE '^[[:space:]]*Singleton[[:space:]]*\{' $file 2>/dev/null
        if not grep -qE '^[[:space:]]*import[[:space:]]+Quickshell([[:space:];]|$)' $file 2>/dev/null
            echo "ERROR: $basename: Singleton requires 'import Quickshell'" >&2
            set fatal_errors (math $fatal_errors + 1)
        end
    end

    # Advisory checks. Keep these non-fatal because the repository still has
    # intentional legacy patterns that should be cleaned independently.
    if grep -qE 'Config\.options\.[a-zA-Z]+\.[a-zA-Z]+[^?]' $file 2>/dev/null
        if not grep -qE 'Config\.options\?\.' $file 2>/dev/null
            echo "WARN: $basename: Config access may need optional chaining (?.)"
            set warnings (math $warnings + 1)
        end
    end

    if grep -qE 'color:[[:space:]]*"#[0-9a-fA-F]{6}"' $file 2>/dev/null
        echo "WARN: $basename: hardcoded color found"
        set warnings (math $warnings + 1)
    end

    if grep -qE 'function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\([^)]*\)[[:space:]]*\{' $file 2>/dev/null
        if grep -qE 'IpcHandler' $file 2>/dev/null
            if not grep -qE 'function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\([^)]*\):[[:space:]]*[A-Za-z_]+' $file 2>/dev/null
                echo "WARN: $basename: IPC function may need a return type annotation"
                set warnings (math $warnings + 1)
            end
        end
    end
end

if test -z "$parser"
    echo "qml-check: qmlformat unavailable; startup guards ran, parser pass skipped" >&2
end

if test $fatal_errors -gt 0
    echo "qml-check: $fatal_errors fatal issue(s), $warnings warning(s)" >&2
    exit 1
end

if test $warnings -gt 0
    echo "qml-check: no fatal issues; $warnings warning(s)"
end

exit 0
