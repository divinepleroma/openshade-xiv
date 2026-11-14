#!/usr/bin/env bash
# Offline tests for OpenShade.ps1 using fake assets. Usage: run_tests.sh <powershell|pwsh>
SHELL_EXE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Everything the tests create goes under this folder (ignored by git).
T="${OPENSHADE_TEST_WORK:-$HERE/.work}"; mkdir -p "$T"; export OPENSHADE_TEST_WORK="$T"
SCRIPT="$(cygpath -w "$REPO/OpenShade.ps1")"
TW="$(cygpath -w "$T")"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
run() { # run <case> <extra args...>
  local c="$1"; shift
  "$SHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" -GamePath "$TW\\$c\\FakeGame\\game" \
    -ManifestPath "$TW\\$c\\manifest.json" -CacheDir "$TW\\$c\\cache" -AssumeYes "$@" > "$T/$c/out-$SHELL_EXE.txt" 2>&1
  echo $?
}

python -I "$HERE/make_fixtures.py" good exe addon toplevel traversal badhash > /dev/null
G="$T/good/FakeGame/game"

echo "== $SHELL_EXE: preview =="
rc=$(run good -DryRun)
check "preview exits 0" "[ $rc = 0 ]"
check "preview leaves dxgi.dll alone" "grep -q 'some other tool' '$G/dxgi.dll'"
check "preview creates no record folder" "[ ! -e '$G/.openshade-xiv' ]"
check "preview unpacks nothing" "[ ! -e '$G/reshade-presets' ]"

echo "== $SHELL_EXE: install =="
rc=$(run good)
check "install exits 0" "[ $rc = 0 ]"
check "dxgi.dll is the extracted ReShade file" "grep -q 'FAKE RESHADE 64 DLL' '$G/dxgi.dll'"
check "new shader unpacked" "[ -f '$G/reshade-shaders/Shaders/new.fx' ]"
check "preset with apostrophe in folder name unpacked" "[ -f \"$G/reshade-presets/Witch's Presets/Moon.ini\" ]"
check "ReShade.ini unpacked" "[ -f '$G/ReShade.ini' ]"
check "old shader no longer in live folder" "[ ! -e '$G/reshade-shaders/Shaders/old.fx' ]"
check "old shader is in backup" "ls '$G'/.openshade-xiv/backup/*/reshade-shaders/Shaders/old.fx > /dev/null 2>&1"
check "old dxgi.dll is in backup" "grep -q 'some other tool' '$G'/.openshade-xiv/backup/*/dxgi.dll"
check "install record written" "[ -f '$G/.openshade-xiv/install-record.json' ]"

echo "== $SHELL_EXE: uninstall =="
rc=$(run good -Uninstall)
check "uninstall exits 0" "[ $rc = 0 ]"
check "original dxgi.dll restored" "grep -q 'some other tool' '$G/dxgi.dll'"
check "original shader restored" "[ -f '$G/reshade-shaders/Shaders/old.fx' ]"
check "installed shader removed" "[ ! -e '$G/reshade-shaders/Shaders/new.fx' ]"
check "presets removed" "[ ! -e '$G/reshade-presets' ]"
check "ReShade.ini removed" "[ ! -e '$G/ReShade.ini' ]"
check "record folder removed" "[ ! -e '$G/.openshade-xiv' ]"

echo "== $SHELL_EXE: uninstall with no record =="
rc=$(run good -Uninstall)
check "refuses (exit 1)" "[ $rc = 1 ]"
check "still untouched" "grep -q 'some other tool' '$G/dxgi.dll'"

echo "== $SHELL_EXE: install twice, then uninstall =="
python -I "$HERE/make_fixtures.py" good > /dev/null
cp "$T/good/cache/FakePack.zip" "$T/good/FakePack.keep"
rc=$(run good)
check "first install exits 0" "[ $rc = 0 ]"
echo "my saved preset" > "$G/reshade-presets/mine.ini"
cp "$T/good/FakePack.keep" "$T/good/cache/FakePack.zip"
rc=$(run good)
check "second install exits 0" "[ $rc = 0 ]"
check "second install says it is a refresh" "grep -q 'previous install by this tool was found' '$T/good/out-$SHELL_EXE.txt'"
check "ReShade still in place after refresh" "grep -q 'FAKE RESHADE 64 DLL' '$G/dxgi.dll'"
check "saved preset kept in a previous-install backup" "ls '$G'/.openshade-xiv/backup/*-previous-install/reshade-presets/mine.ini > /dev/null 2>&1"
rc=$(run good -Uninstall)
check "uninstall after refresh exits 0" "[ $rc = 0 ]"
check "original dxgi.dll restored" "grep -q 'some other tool' '$G/dxgi.dll'"
check "original shader restored" "[ -f '$G/reshade-shaders/Shaders/old.fx' ]"
check "installed shader removed" "[ ! -e '$G/reshade-shaders/Shaders/new.fx' ]"
check "presets folder removed" "[ ! -e '$G/reshade-presets' ]"
check "install record removed" "[ ! -e '$G/.openshade-xiv/install-record.json' ]"
check "saved preset still recoverable from backup" "ls '$G'/.openshade-xiv/backup/*-previous-install/reshade-presets/mine.ini > /dev/null 2>&1"

for c in exe addon toplevel traversal badhash; do
  echo "== $SHELL_EXE: refuses '$c' =="
  B="$T/$c/FakeGame/game"
  rc=$(run $c)
  check "exits 1" "[ $rc = 1 ]"
  check "dxgi.dll untouched" "grep -q 'some other tool' '$B/dxgi.dll'"
  check "nothing unpacked" "[ ! -e '$B/reshade-presets' ] && [ ! -e '$B/ReShade.ini' ]"
  check "old shader still in place" "[ -f '$B/reshade-shaders/Shaders/old.fx' ]"
  check "nothing written outside game folder" "[ ! -e '$T/$c/outside.txt' ] && [ ! -e '$T/$c/FakeGame/outside.txt' ]"
  echo "     reason given: $(grep -E "contains an unexpected item|outside the game folder|program or script|does not match the checksum" "$T/$c/out-$SHELL_EXE.txt" | head -1 | cut -c1-110)"
done

echo "== $SHELL_EXE: $pass passed, $fail failed =="
[ "$fail" = 0 ]
