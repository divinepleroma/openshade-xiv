#!/usr/bin/env bash
# Tests for the failsafe features: detection, self-checks, verification,
# download handling and launcher guards. Usage: failsafe.sh <powershell|pwsh>
# SAFETY RULE: any run without -GamePath uses -DryRun, because detection may
# find the real game on this machine.
SH="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Everything the tests create goes under this folder (ignored by git).
T="${OPENSHADE_TEST_WORK:-$HERE/.work}"; mkdir -p "$T"; export OPENSHADE_TEST_WORK="$T"
SRC="$REPO"
BASE="$T/fs-$SH"
PORT=18765; [ "$SH" = pwsh ] && PORT=18766
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

rm -rf "$BASE"; mkdir -p "$BASE"
python -I "$HERE/make_fixtures.py" good casecollide > /dev/null
FX="$T/good"
python -I - "$FX/cache/FakeSetup.exe" "$BASE/fake64.dll" <<'EOF'
import io, sys, zipfile
d = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(zipfile.ZipFile(io.BytesIO(d[1024:])).read("ReShade64.dll"))
EOF
COPY="$BASE/Downloads/openshade-xiv-main (1)"
mkdir -p "$COPY" && cp "$SRC/OpenShade.ps1" "$SRC/OpenShade.cmd" "$SRC/manifest.json" "$COPY"/
COPYW="$(cygpath -w "$COPY")"
MANW="$(cygpath -w "$FX/manifest.json")"

mkgame() { mkdir -p "$1/sqpack" && : > "$1/ffxiv_dx11.exe" && echo 2026.01.01.0000.0000 > "$1/ffxivgame.ver"; }
new_env() { # new_env <name> [nocache] [subpath-for-game]
  E="$BASE/$1"
  mkdir -p "$E/Local/openshade-xiv/downloads" "$E/Roaming" "$E/Temp"
  [ "$2" = nocache ] || cp "$FX/cache/FakeSetup.exe" "$FX/cache/FakePack.zip" "$E/Local/openshade-xiv/downloads/"
  GAME="$E/${3:-FFXIV/game}"
  mkgame "$GAME"
  GAMEW="$(cygpath -w "$GAME")"
  OUT="$E/out.txt"
}
go() { # go <answers> <args...>
  local answers="$1"; shift
  printf "$answers" | env LOCALAPPDATA="$(cygpath -w "$E/Local")" APPDATA="$(cygpath -w "$E/Roaming")" \
    TEMP="$(cygpath -w "$E/Temp")" TMP="$(cygpath -w "$E/Temp")" "${EXTRA_ENV[@]}" \
    "$SH" -NoProfile -ExecutionPolicy Bypass -File "$COPYW\\OpenShade.ps1" -ManifestPath "$MANW" "$@" > "$OUT" 2>&1
  RC=$?
}
EXTRA_ENV=()
pristine() { [ "$(ls -A "$GAME" | tr '\n' ' ')" = "ffxiv_dx11.exe ffxivgame.ver sqpack " ]; }

echo "== $SH: self-check and incomplete game folder =="
new_env f1; rm -rf "$GAME/sqpack" "$GAME/ffxivgame.ver"; go 'y\nn\n' -GamePath "$GAMEW"
check "self-check passes" "grep -q 'Installs:' '$OUT' && ! grep -q 'System check failed' '$OUT'"
check "warns the folder looks incomplete" "grep -q 'not the rest of the game files' '$OUT'"
check "answering No stops with no changes" "[ $RC = 1 ] && [ \"\$(ls -A '$GAME')\" = 'ffxiv_dx11.exe' ]"

echo "== $SH: detection from XIVLauncher settings (preview only) =="
new_env f2 "" "XL Root/game"
printf '{"GamePath": "%s"}' "$(cygpath -w "$E/XL Root" | sed 's/\\/\\\\/g')" > "$E/Roaming/XIVLauncher.tmp"
mkdir -p "$E/Roaming/XIVLauncher" && mv "$E/Roaming/XIVLauncher.tmp" "$E/Roaming/XIVLauncher/launcherConfigV3.json"
go 'y\n\nq\n' -DryRun
check "lists the folder with its source" "grep -F 'XL Root\\game' '$OUT' | grep -q 'source: XIVLauncher settings'"
check "shows the game version" "grep -F 'XL Root\\game' '$OUT' | grep -q 'game version 2026.01.01.0000.0000'"
check "changed nothing" "pristine"
if tasklist 2>/dev/null | grep -qi ffxiv_dx11; then
  check "also finds the copy that is running now" "grep -q 'running game process' '$OUT'"
fi

echo "== $SH: detection from a Steam library in a custom place (preview only) =="
new_env f3 "" "SteamLib/steamapps/common/FFXIV Custom Dir/game"
mkdir -p "$E/PF86/Steam/steamapps"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$(cygpath -w "$E/SteamLib" | sed 's/\\/\\\\\\\\/g')" > "$E/PF86/Steam/steamapps/libraryfolders.vdf"
printf '"AppState"\n{\n\t"appid"\t\t"39210"\n\t"installdir"\t\t"FFXIV Custom Dir"\n}\n' > "$E/SteamLib/steamapps/appmanifest_39210.acf"
EXTRA_ENV=("ProgramFiles(x86)=$(cygpath -w "$E/PF86")")
go 'y\n\nq\n' -DryRun
EXTRA_ENV=()
check "finds it through Steam's own records" "grep -F 'FFXIV Custom Dir\\game' '$OUT' | grep -q 'source: Steam'"
check "changed nothing" "pristine"

echo "== $SH: path given as the boot folder or launcher =="
new_env f4 "" "FINAL FANTASY XIV - A Realm Reborn/game"; mkdir -p "$(dirname "$GAME")/boot"; : > "$(dirname "$GAME")/boot/ffxivboot.exe"
go 'y\n' -DryRun -GamePath "$(cygpath -w "$(dirname "$GAME")/boot/ffxivboot.exe")"
check "launcher path resolves to the game folder" "[ $RC = 0 ] && grep -q 'Realm Reborn.game' '$OUT' && grep -q 'Preview complete' '$OUT'"
go 'y\n' -DryRun -GamePath "\"$GAMEW\""
check "path wrapped in quotes is accepted" "[ $RC = 0 ] && grep -q 'Preview complete' '$OUT'"

echo "== $SH: install, then the Check tool =="
new_env f5; go 'y\ny\nn\n' -GamePath "$GAMEW"
check "install passes its own double-check" "[ $RC = 0 ] && grep -q 'All checks passed' '$OUT' && grep -q 'All pack files present and correct size' '$OUT'"
check "record marked complete with a file count" "grep -q '\"completed\": *true' '$GAME/.openshade-xiv/install-record.json' && grep -q '\"packFileCount\": *4' '$GAME/.openshade-xiv/install-record.json'"
go '' -Check -GamePath "$GAMEW"
check "Check passes (exit 0)" "[ $RC = 0 ] && grep -q 'All installed files are in place' '$OUT'"
check "Check says ReShade has not started yet" "grep -q 'has not started with the game yet' '$OUT'"
sleep 1; printf "12:00:00:000 [ 1] | INFO  | Initializing crosire's ReShade version '6.5.1.1946' (64-bit) loaded from x\r\n" > "$GAME/ReShade.log"; touch -d '+1 hour' "$GAME/ReShade.log"
go '' -Check -GamePath "$GAMEW"
check "Check reports ReShade started, with version" "grep -q 'ReShade last started with the game' '$OUT' && grep -q '6.5.1.1946' '$OUT'"
before="$(find "$GAME" -type f | sort | xargs -d '\n' sha256sum | sha256sum)"
go '' -Check -GamePath "$GAMEW"
check "Check changes nothing" "[ \"\$(find '$GAME' -type f | sort | xargs -d '\n' sha256sum | sha256sum)\" = '$before' ]"
rm "$GAME/reshade-shaders/Shaders/new.fx"; go '' -Check -GamePath "$GAMEW"
check "Check notices a missing pack file" "[ $RC = 1 ] && grep -q 'missing since install' '$OUT'"
echo tampered > "$GAME/dxgi.dll"; go '' -Check -GamePath "$GAMEW"
check "Check notices a replaced ReShade file" "[ $RC = 1 ] && grep -q 'differs from the installed version' '$OUT'"
rm "$GAME/dxgi.dll"; go '' -Check -GamePath "$GAMEW"
check "Check notices a removed ReShade file" "[ $RC = 1 ] && grep -q 'security software' '$OUT'"
go 'y\ny\nn\n' -GamePath "$GAMEW"
check "running Install again repairs it" "[ $RC = 0 ] && grep -q 'All checks passed' '$OUT' && cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll' && [ -f '$GAME/reshade-shaders/Shaders/new.fx' ]"
new_env f5b; go '' -Check -GamePath "$GAMEW"
check "Check on a folder never installed to just describes it" "[ $RC = 0 ] && grep -q 'No install by this tool was found here' '$OUT' && pristine"

echo "== $SH: the double-check catches a bad unpack =="
new_env f6; cp "$T/casecollide/cache/FakePack.zip" "$E/Local/openshade-xiv/downloads/FakePack.zip"
MANW_SAVE="$MANW"; MANW="$(cygpath -w "$T/casecollide/manifest.json")"
go 'y\ny\nn\n' -GamePath "$GAMEW"
MANW="$MANW_SAVE"
check "reports the install is not complete (exit 1)" "[ $RC = 1 ] && grep -q 'check(s) failed' '$OUT'"
check "record left marked incomplete" "grep -q '\"completed\": *false' '$GAME/.openshade-xiv/install-record.json'"
go 'y\n' -GamePath "$GAMEW" -Uninstall
check "uninstall still restores the folder" "[ $RC = 0 ] && pristine"

echo "== $SH: game path too long for the pack =="
base_len=$(cygpath -w "$BASE/f7" | tr -d '\r\n' | wc -c)
pad=$((236 - base_len - 7)); [ "$pad" -lt 4 ] && pad=4
LONG="$(printf 'a%.0s' $(seq 1 $((pad / 2))))/$(printf 'b%.0s' $(seq 1 $((pad - pad / 2))))/game"
new_env f7 "" "$LONG"; go 'y\ny\n' -GamePath "$GAMEW"
check "stops before unpacking (exit 1)" "[ $RC = 1 ] && grep -q 'too long' '$OUT'"
check "nothing changed" "pristine"

echo "== $SH: game path with accents and Japanese characters =="
new_env f8 "" "Spiele öé 日本語/game"; go 'y\ny\nn\n' -GamePath "$GAMEW"
check "installs and passes its double-check" "[ $RC = 0 ] && grep -q 'All checks passed' '$OUT' && cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll'"

echo "== $SH: downloads from a local test web server =="
(cd "$FX/cache" && exec python -I -m http.server $PORT --bind 127.0.0.1 > /dev/null 2>&1) &
SRV=$!; sleep 2
mkman() { python -I - "$FX/manifest.json" "$1" "$PORT" "$2" <<'EOF'
import json, sys
src, dst, port, mode = sys.argv[1:5]
m = json.load(open(src))
base = "http://127.0.0.1:%s/" % port
m["reshade"]["url"] = base + "FakeSetup.exe"
m["gposingway"]["url"] = base + "FakePack.zip"
if mode == "404": m["gposingway"]["url"] = base + "gone.zip"
if mode == "size": m["gposingway"]["size"] += 1
if mode == "hash": m["gposingway"]["sha256"] = "0" * 64
json.dump(m, open(dst, "w"), indent=2)
EOF
}
dl() { # dl <name> <mode> <answers>
  new_env "$1" nocache; mkman "$E/manifest.json" "$2"
  MANW_SAVE="$MANW"; MANW="$(cygpath -w "$E/manifest.json")"; go "$3" -GamePath "$GAMEW"; MANW="$MANW_SAVE"
}
dl f9a ok 'y\ny\nn\n'
check "downloads, verifies and installs" "[ $RC = 0 ] && grep -q 'Checksum verified' '$OUT' && grep -q 'All checks passed' '$OUT'"
dl f9b 404 'y\ny\n'
check "missing file: explains and changes nothing" "[ $RC = 1 ] && grep -q 'returned an error (404)' '$OUT' && pristine"
dl f9c size 'y\ny\n'
check "changed size: refuses before downloading" "[ $RC = 1 ] && grep -q 'different size than expected' '$OUT' && pristine"
dl f9d hash 'y\ny\n'
check "wrong fingerprint: deletes download, changes nothing" "[ $RC = 1 ] && grep -q 'does not match the checksum' '$OUT' && [ ! -e '$E/Local/openshade-xiv/downloads/FakePack.zip' ] && pristine"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
dl f9e ok 'y\nn\n'
check "site unreachable: offers a retry, then explains" "[ $RC = 1 ] && grep -q \"Download from\" '$OUT' && grep -q \"Could not download\" '$OUT' && pristine"

echo "== $SH: damaged or missing manifest =="
new_env f10; echo '{ not json' > "$E/bad.json"
MANW_SAVE="$MANW"; MANW="$(cygpath -w "$E/bad.json")"; go 'y\n' -GamePath "$GAMEW"
check "damaged manifest explained" "[ $RC = 1 ] && grep -q 'manifest.json is damaged' '$OUT'"
MANW="$(cygpath -w "$E/nope.json")"; go 'y\n' -GamePath "$GAMEW"; MANW="$MANW_SAVE"
check "missing manifest mentions unzipping" "[ $RC = 1 ] && grep -q 'Extract All' '$OUT'"

echo "== $SH: only one copy at a time =="
new_env f11
(sleep 12 | env LOCALAPPDATA="$(cygpath -w "$E/Local")" "$SH" -NoProfile -ExecutionPolicy Bypass -File "$COPYW\\OpenShade.ps1" -ManifestPath "$MANW" -DryRun -GamePath "$GAMEW" > "$E/first.txt" 2>&1) &
FIRST=$!; sleep 5
go 'y\n' -DryRun -GamePath "$GAMEW"
check "second window is refused" "[ $RC = 1 ] && grep -q 'Another instance is already running' '$OUT'"
wait $FIRST 2>/dev/null
go 'y\n' -DryRun -GamePath "$GAMEW"
check "works again once the first has closed" "[ $RC = 0 ] && grep -q 'Preview complete' '$OUT'"

echo "== $SH: locked-down PowerShell (constrained language mode) =="
new_env f12
env LOCALAPPDATA="$(cygpath -w "$E/Local")" "$SH" -NoProfile -ExecutionPolicy Bypass -Command "\$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$COPYW\\OpenShade.ps1' -DryRun -AssumeYes -GamePath '$GAMEW' -ManifestPath '$MANW'; exit \$LASTEXITCODE" > "$OUT" 2>&1; RC=$?
check "explains it cannot run here" "grep -q 'PowerShell on this PC is restricted' '$OUT'"
check "exits 1 without touching the game" "[ $RC = 1 ] && pristine"

echo "== $SH: menu =="
new_env m1; go 'q\n' -Menu -GamePath "$GAMEW"
check "Q quits without changes" "[ $RC = 0 ] && grep -q 'Install or repair' '$OUT' && pristine"
new_env m2; go 'x\n\nzz\n9\n0\n' -Menu -GamePath "$GAMEW"
check "five unusable answers quit without changes" "[ $RC = 0 ] && pristine"
new_env m3; go '2\ny\n' -Menu -GamePath "$GAMEW"
check "2 runs the preview" "[ $RC = 0 ] && grep -q 'PREVIEW MODE' '$OUT' && grep -q 'Preview complete' '$OUT' && pristine"
go '1\ny\ny\nn\n' -Menu -GamePath "$GAMEW"
check "1 installs" "[ $RC = 0 ] && grep -q 'All checks passed' '$OUT' && cmp -s '$GAME/dxgi.dll' '$BASE/fake64.dll'"
go '3\n' -Menu -GamePath "$GAMEW"
check "3 runs the check" "[ $RC = 0 ] && grep -q 'install check (read-only)' '$OUT' && grep -q 'All installed files are in place' '$OUT'"
go '4\ny\n' -Menu -GamePath "$GAMEW"
check "4 uninstalls" "[ $RC = 0 ] && grep -q 'Uninstall complete' '$OUT' && pristine"

if [ "$SH" = powershell ]; then
  echo "== launcher opened from inside a zip (only the .cmd present) =="
  mkdir -p "$BASE/zipview" && cp "$SRC/OpenShade.cmd" "$BASE/zipview/"
  printf '\n' | powershell -NoProfile -Command "& '$(cygpath -w "$BASE/zipview")\\OpenShade.cmd'" > "$BASE/zipview/out.txt" 2>&1
  check "tells the player to extract the zip first" "grep -q 'Extract All' '$BASE/zipview/out.txt'"
  echo "== OpenShade.cmd launcher =="
  E="$BASE/m1"
  printf 'q\n\n' | env LOCALAPPDATA="$(cygpath -w "$E/Local")" APPDATA="$(cygpath -w "$E/Roaming")" powershell -NoProfile -Command "& '$COPYW\\OpenShade.cmd'" > "$E/launcher.txt" 2>&1
  check "OpenShade.cmd opens the menu" "grep -q 'Install or repair' '$E/launcher.txt' && grep -q 'Choose' '$E/launcher.txt' || grep -q 'Q. Quit' '$E/launcher.txt'"
fi

echo "== $SH: $pass passed, $fail failed =="
[ "$fail" = 0 ]
