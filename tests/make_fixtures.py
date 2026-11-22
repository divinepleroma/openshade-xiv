"""Build fake assets and manifests so the walkthrough can be tested offline."""
import hashlib
import io
import json
import os
import shutil
import sys
import zipfile

ROOT = os.environ.get("OPENSHADE_TEST_WORK") or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".work")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_zip(entries) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            z.writestr(name, data)
    return buf.getvalue()


def fresh(path):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)


def build(case: str):
    base = os.path.join(ROOT, case)
    fresh(base)
    cache = os.path.join(base, "cache")
    game = os.path.join(base, "FakeGame", "game")
    os.makedirs(cache)
    os.makedirs(game)
    open(os.path.join(game, "ffxiv_dx11.exe"), "wb").close()
    with open(os.path.join(game, "ffxivgame.ver"), "w") as f:
        f.write("2026.01.01.0000.0000")
    os.makedirs(os.path.join(game, "sqpack"))

    # Things that already exist and must be backed up.
    os.makedirs(os.path.join(game, "reshade-shaders", "Shaders"))
    with open(os.path.join(game, "reshade-shaders", "Shaders", "old.fx"), "w") as f:
        f.write("old shader")
    with open(os.path.join(game, "dxgi.dll"), "wb") as f:
        f.write(b"some other tool")
    with open(os.path.join(game, "ReShadePreset.ini"), "w") as f:
        f.write("old preset state")

    dll = b"FAKE RESHADE 64 DLL" * 100
    inner = make_zip([("ReShade32.dll", b"x86"), ("ReShade64.dll", dll), ("ReShade64.json", b"{}")])
    setup = (b"MZ" + b"\0" * 1022) + inner  # 1024-byte stub, then the archive
    with open(os.path.join(cache, "FakeSetup.exe"), "wb") as f:
        f.write(setup)

    good = [
        ("ReShade.ini", b"[GENERAL]\r\nEffectSearchPaths=.\\reshade-shaders\\Shaders\\**\r\nTextureSearchPaths=.\\reshade-shaders\\Textures\\**\r\n"
                        b"\r\n[SCREENSHOT]\r\nSavePath=.\\fake-screenshots\\\r\n"),
        ("reshade-presets/", b""),
        ("reshade-presets/Witch's Presets/Moon.ini", b"preset"),
        ("reshade-shaders/Shaders/new.fx", b"shader"),
        ("reshade-shaders/Textures/lut.png", b"png"),
    ]
    packs = {
        "good": good,
        "exe": good + [("reshade-shaders/Shaders/helper.exe", b"MZ")],
        "addon": good + [("reshade-shaders/thing.addon64", b"MZ")],
        "toplevel": good + [("dxgi.dll", b"MZ")],
        "traversal": good + [("reshade-shaders/../../outside.txt", b"escape")],
        "casecollide": good + [("reshade-shaders/Shaders/Same.fx", b"first version"), ("reshade-shaders/Shaders/same.fx", b"2nd")],
    }
    pack = make_zip(packs[case if case in packs else "good"])
    with open(os.path.join(cache, "FakePack.zip"), "wb") as f:
        f.write(pack)

    manifest = {
        "manifestVersion": 1,
        "updated": "test",
        "reshade": {
            "name": "Fake ReShade", "version": "0.0.1", "homepage": "https://example.invalid",
            "url": "https://example.invalid/FakeSetup.exe", "fileName": "FakeSetup.exe",
            "size": len(setup), "sha256": sha(setup),
            "dllEntry": "ReShade64.dll", "dllSha256": sha(dll), "installAs": "dxgi.dll",
        },
        "gposingway": {
            "name": "Fake Pack", "version": "0.0.1", "releaseTag": "T1", "homepage": "https://example.invalid",
            "url": "https://example.invalid/FakePack.zip", "fileName": "FakePack.zip",
            "size": len(pack), "sha256": sha(pack),
            "allowedTopLevel": ["ReShade.ini", "reshade-presets", "reshade-shaders"],
        },
    }
    if case == "badhash":
        manifest["gposingway"]["sha256"] = "0" * 64
    with open(os.path.join(base, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("built", case)


for c in sys.argv[1:]:
    build(c)
