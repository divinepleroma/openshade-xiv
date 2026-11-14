![OpenShade XIV](images/banner.jpg)

[![License](https://img.shields.io/github/license/divinepleroma/openshade-xiv?style=flat)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-4c8eda?style=flat)
[![ReShade](https://img.shields.io/badge/ReShade-6.8.0-8a5cf5?style=flat)](https://github.com/crosire/reshade)
[![GPosingway](https://img.shields.io/badge/GPosingway-8.3.1-e667af?style=flat)](https://github.com/gposingway/gposingway)

A safe, auditable installer for [ReShade](https://github.com/crosire/reshade) and [GPosingway](https://github.com/gposingway/gposingway) on FINAL FANTASY XIV, written as a single readable PowerShell script.

## Features

- **Verified downloads.** Every file is checked against a pinned SHA-256 checksum before it is used.
- **Official sources only.** ReShade and GPosingway are fetched from their own download pages. Nothing is rehosted here.
- **Nothing hidden.** One script you can open and read. No compiled program, no background process, no auto-update.
- **Finds your game.** Custom install folders, Steam libraries and XIVLauncher installs are detected without scanning your drives.
- **Reversible.** Existing files are backed up first, and `Uninstall.cmd` puts them back.
- **Checks its own work.** The install is verified when it finishes, and `Check.cmd` can repeat that at any time.

## Installation

> [!WARNING]
> The only official source for OpenShade XIV is this GitHub repository.

1. Click **Code** > **Download ZIP**, or use the [direct download](https://github.com/divinepleroma/openshade-xiv/archive/refs/heads/main.zip).
2. Right-click the zip and choose **Extract All**. Do not run it from inside the zip.
3. Close the game.
4. Open the extracted folder and run **`Install.cmd`**.

In game, **Shift+F2** opens the ReShade menu and **Shift+F3** toggles effects.

> [!NOTE]
> Windows may ask for confirmation before running a downloaded script. OpenShade XIV is plain text, so you can open `OpenShade.ps1` in Notepad and read it first.

> [!TIP]
> Not sure yet? Run `Preview.cmd`. It walks through every step and changes nothing.

<details>
  <summary>
    <b>Requirements</b>
  </summary>

  - Windows 10 or 11, 64-bit (tested on Windows 11)
  - Windows PowerShell 5.1, which is included with Windows
  - About 1 GB of free disk space
  - FINAL FANTASY XIV, DirectX 11 client
</details>

## Usage

| File | Purpose |
|---|---|
| `Preview.cmd` | Shows every step. Downloads and changes nothing. |
| `Install.cmd` | Installs, then verifies the result. Also repairs an existing install. |
| `Check.cmd` | Read-only. Reports whether the install is complete and whether ReShade has started with the game. |
| `Uninstall.cmd` | Removes what was installed and restores what was backed up. |

## What gets installed

| Component | Version | Project | Downloaded from |
|---|---|---|---|
| ReShade, add-on edition | 6.8.0 | [crosire/reshade](https://github.com/crosire/reshade) | reshade.me, ReShade's own download site |
| GPosingway | 8.3.1 (release R8.2.1) | [gposingway/gposingway](https://github.com/gposingway/gposingway) | GPosingway's GitHub releases |

Versions, download addresses and SHA-256 checksums are pinned in [`manifest.json`](manifest.json). Nothing else is downloaded.

## Preview

```text
OpenShade XIV 0.3.3
ReShade + GPosingway setup for FINAL FANTASY XIV
[ok] System check passed.

Installs:
  ReShade 6.8.0 (add-on edition)   https://github.com/crosire/reshade
  GPosingway 8.3.1   https://github.com/gposingway/gposingway

Files are downloaded from their official sources and verified against
the SHA-256 checksums in manifest.json. Existing files are backed up
before being replaced. Nothing outside the game folder is modified.

Unofficial community tool. Not affiliated with Square Enix.

Continue? [Y/N]:
```

## Details

<details>
  <summary>
    <b>How it works</b>
  </summary>

  1. **Locate game.** Reads existing records only; no drive scan. Sources: the running game process, XIVLauncher settings, the installed programs list, Steam library records, Desktop and Start menu shortcuts, recently run programs, and the default install folders. Multiple installs are listed with game version and last patch date. A folder can also be browsed for or pasted.
  2. **Existing files.** Anything that would be replaced is moved to a backup folder inside the game folder.
  3. **ReShade.** Downloads the official setup file, verifies it, and extracts `ReShade64.dll` without running the setup program. It is installed as `dxgi.dll`.
  4. **GPosingway.** Downloads the release package, verifies it, and inspects every entry before unpacking.
  5. **Install.** Lists every change and asks for confirmation first.
  6. **Verify.** Compares the installed files against the package and confirms ReShade is present and unmodified.
</details>

<details>
  <summary>
    <b>Safeguards</b>
  </summary>

  - A system check runs first and stops if the PC cannot run the tool (for example, restricted PowerShell on a managed computer).
  - Downloads are refused if the size or SHA-256 checksum does not match the manifest.
  - The package is refused if it contains a program or script, an unexpected top-level item, or a path outside the game folder.
  - The install stops if GShade is present, the game is running, the game folder is not writable, or the folder path is too long for the package.
  - A second copy of ReShade under another file name is moved to the backup.
  - Only one instance can run at a time.
  - If a run fails partway, the tool reports whether the game folder was changed and how to restore it.
</details>

<details>
  <summary>
    <b>Files and locations</b>
  </summary>

  | Location | Contents |
  |---|---|
  | `<game folder>\.openshade-xiv` | Install record and backups |
  | `%LOCALAPPDATA%\openshade-xiv` | Downloads and `log.txt` |
</details>

<details>
  <summary>
    <b>Troubleshooting</b>
  </summary>

  - **"Cannot write to the game folder".** Right-click `Install.cmd` and choose **Run as administrator**. This is common when the game is in `Program Files`.
  - **The script is blocked from running.** Some managed work or school PCs do not allow downloaded scripts. The tool cannot run there.
  - **No ReShade banner in game.** Run `Check.cmd`, then see GPosingway's [troubleshooting guide](https://github.com/gposingway/gposingway/blob/main/md/troubleshooting.md).
</details>

<details>
  <summary>
    <b>Updating the manifest</b>
  </summary>

  When a new ReShade or GPosingway version is adopted:

  1. Set the new `version`, `url`, `fileName` and `size`.
  2. Set `sha256` to the SHA-256 of the downloaded file. For GPosingway, GitHub shows this as the asset digest on the release page.
  3. For ReShade, also set `dllSha256` to the SHA-256 of `ReShade64.dll` inside the setup file.
  4. Run `Preview.cmd`, then a full install into a test folder.

  Do not point the manifest at a "latest" address. A pinned version with a pinned checksum is what makes the download verifiable.
</details>

## Credits

- [ReShade](https://github.com/crosire/reshade) by crosire.
- [GPosingway](https://github.com/gposingway/gposingway) and its contributors. Each shader and preset collection it contains has its own licence; see its [shader licences](https://github.com/gposingway/gposingway/blob/main/md/shader_licenses.md).
- Banner and icon made from an in-game screenshot by [divinepleroma](https://github.com/divinepleroma).

---

Released under the [MIT licence](LICENSE), which covers only the files in this project.

##### FINAL FANTASY XIV © SQUARE ENIX CO., LTD. All Rights Reserved. OpenShade XIV is not affiliated with SQUARE ENIX CO., LTD. in any way.
