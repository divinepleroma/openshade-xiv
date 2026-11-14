#!/usr/bin/env bash
# Scenario tests in a simulated clean user profile, answering prompts on stdin
# like a player would. Usage: scenarios.sh <powershell|pwsh>
SH="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Everything the tests create goes under this folder (ignored by git).
T="${OPENSHADE_TEST_WORK:-$HERE/.work}"; mkdir -p "$T"; export OPENSHADE_TEST_WORK="$T"
SRC="$REPO"
BASE="$T/cleanenv-$SH"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

rm -rf "$BASE"; mkdir -p "$BASE"
python -I "$HERE/make_fixtures.py" good > /dev/null
FX="$T/good"
python -I - "$FX/cache/FakeSetup.exe" "$BASE/fake64.dll" <<'EOF'
import io, sys, zipfile
d = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(zipfile.ZipFile(io.BytesIO(d[1024:])).read("ReShade64.dll"))
EOF

# The project as a player would have it: unzipped into Downloads, odd folder name.
COPY="$BASE/Downloads/openshade-xiv-main (1)"
mkdir -p "$COPY" && cp "$SRC/OpenShade.ps1" "$SRC/OpenShade.cmd" "$SRC/manifest.json" "$COPY"/
COPYW="$(cygpath -w "$COPY")"
MANW="$(cygpath -w "$FX/manifest.json")"

# new_env <name>: fresh profile folders, seeded download cache, realistic game path.
new_env() {
  E="$BASE/$1"
  mkdir -p "$E/Local/openshade-xiv/downloads" "$E/Roaming" "$E/Temp"
  cp "$FX/cache/FakeSetup.exe" "$FX/cache/FakePack.zip" "$E/Local/openshade-xiv/downloads/"
  GAME="$E/Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/game"
  mkdir -p "$GAME/sqpack" && : > "$GAME/ffxiv_dx11.exe" && echo 2026.01.01.0000.0000 > "$GAME/ffxivgame.ver"
  GAMEW="$(cygpath -w "$GAME")"
  OUT="$E/out.txt"
}
# go <answers> <args...>: run the walkthrough inside the clean profile.
go() {
  local answers="$1"; shift
  printf "$answers" | LOCALAPPDATA="$(cygpath -w "$E/Local")" APPDATA="$(cygpath -w "$E/Roaming")" \
    TEMP="$(cygpath -w "$E/Temp")" TMP="$(cygpath -w "$E/Temp")" \
    "$SH" -NoProfile -ExecutionPolicy Bypass -File "$COPYW\\OpenShade.ps1" -ManifestPath "$MANW" "$@" > "$OUT" 2>&1
  RC=$?
}
only_exe() { [ "$(ls -A "$GAME" | tr '\n' ' ')" = "ffxiv_dx11.exe ffxivgame.ver sqpack " ]; }

echo "== $SH: new player, default install path with spaces and brackets =="
new_env s1; go 'y\ny\nn\n' -GamePath "$GAMEW"
check "exits 0" "[ $RC = 0 ]"
check "ReShade file installed" "cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll'"
check "preset unpacked" "[ -f \"$GAME/reshade-presets/Witch's Presets/Moon.ini\" ]"
check "said No to deleting the pack, and it was kept" "[ -f '$E/Local/openshade-xiv/downloads/FakePack.zip' ]"
check "log written inside the clean profile" "[ -s '$E/Local/openshade-xiv/log.txt' ]"
check "no errors printed" "! grep -qi 'Unexpected error' '$OUT'"
go 'y\n' -GamePath "$GAMEW" -Uninstall
check "uninstall leaves only the game exe" "[ $RC = 0 ] && only_exe"

echo "== $SH: GShade already installed =="
new_env s2; echo "[x]" > "$GAME/GShade.ini"; go 'y\n' -GamePath "$GAMEW"
check "stops (exit 1)" "[ $RC = 1 ]"
check "explains GShade must go first" "grep -q 'GShade is installed' '$OUT'"
check "nothing added" "[ ! -e '$GAME/dxgi.dll' ] && [ ! -e '$GAME/reshade-shaders' ] && [ ! -e '$GAME/.openshade-xiv' ]"

echo "== $SH: correct ReShade already installed =="
new_env s3; cp "$BASE/fake64.dll" "$GAME/dxgi.dll"; go 'y\ny\nn\n' -GamePath "$GAMEW"
check "exits 0" "[ $RC = 0 ]"
check "says it is already installed" "grep -q 'already installed' '$OUT'"
check "did not back up or replace it" "! ls '$GAME'/.openshade-xiv/backup/*/dxgi.dll > /dev/null 2>&1 && cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll'"
check "pack still installed" "[ -f '$GAME/reshade-shaders/Shaders/new.fx' ]"
go 'y\n' -GamePath "$GAMEW" -Uninstall
check "uninstall keeps the ReShade it did not install" "[ $RC = 0 ] && cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll' && [ ! -e '$GAME/reshade-shaders' ]"

echo "== $SH: unknown dxgi.dll, player answers No =="
new_env s4; echo "another tool" > "$GAME/dxgi.dll"; go 'y\nn\n' -GamePath "$GAMEW"
check "stops (exit 1)" "[ $RC = 1 ]"
check "file left alone" "grep -q 'another tool' '$GAME/dxgi.dll'"
check "nothing else created" "[ ! -e '$GAME/.openshade-xiv' ] && [ ! -e '$GAME/reshade-shaders' ]"

echo "== $SH: game folder is write-protected =="
new_env s5
powershell -NoProfile -Command "icacls '$GAMEW' /deny \"\$env:USERNAME\`:(W)\" | Out-Null"
go 'y\ny\n' -GamePath "$GAMEW"
powershell -NoProfile -Command "icacls '$GAMEW' /remove:d \"\$env:USERNAME\" | Out-Null"
check "stops (exit 1)" "[ $RC = 1 ]"
check "explains the permission problem" "grep -q 'Cannot write to the game folder' '$OUT'"
check "nothing changed" "only_exe"

echo "== $SH: player backs out at the final question =="
new_env s6; go 'y\nn\n' -GamePath "$GAMEW"
check "stops (exit 1)" "[ $RC = 1 ]"
check "says nothing changed" "grep -q 'No changes were made' '$OUT'"
check "game folder untouched" "only_exe"

echo "== $SH: window closed mid-question (no more input) =="
new_env s7; go '' -GamePath "$GAMEW"
check "stops safely (exit 1)" "[ $RC = 1 ]"
check "game folder untouched" "only_exe"

echo "== $SH: different ways of giving the game folder (preview) =="
new_env s8
go 'y\n' -DryRun -GamePath "$GAMEW\\ffxiv_dx11.exe"
check "path to the exe itself" "[ $RC = 0 ] && grep -q 'Preview complete' '$OUT'"
go 'y\n' -DryRun -GamePath "$(cygpath -w "$(dirname "$GAME")")"
check "path to the folder above 'game'" "[ $RC = 0 ] && grep -q 'Preview complete' '$OUT'"
go 'y\n' -DryRun -GamePath "$(cygpath -w "$E")"
check "wrong folder is rejected" "[ $RC = 1 ] && grep -q \"not found in\" '$OUT'"
check "preview changed nothing" "only_exe"

echo "== $SH: $pass passed, $fail failed =="
[ "$fail" = 0 ]
