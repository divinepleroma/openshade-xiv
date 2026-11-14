# OpenShade XIV

OpenShade XIV installs [ReShade](https://reshade.me) and
[GPosingway](https://github.com/gposingway/gposingway) for FINAL FANTASY XIV
from their official sources, with checksum verification, backup and uninstall.

It is open source and consists of a single readable PowerShell script. There is no compiled program, no
background process and no auto-update. This project does not redistribute
ReShade, GPosingway, or any shader or preset.

## Requirements

- Windows 10 or 11, 64-bit (tested on Windows 11)
- Windows PowerShell 5.1, which is included with Windows
- About 1 GB of free disk space
- FINAL FANTASY XIV, DirectX 11 client

## Usage

1. Download this project (**Code** > **Download ZIP**) and extract it
   (right-click the zip > **Extract All**). Do not run it from inside the zip.
2. Close the game.
3. Run **`Install.cmd`**.

In game, **Shift+F2** opens the ReShade menu and **Shift+F3** toggles effects.

| File | Purpose |
|---|---|
| `Preview.cmd` | Shows every step. Downloads and changes nothing. |
| `Install.cmd` | Installs, then verifies the result. Also repairs an existing install. |
| `Check.cmd` | Read-only. Reports whether the install is complete and whether ReShade has started with the game. |
| `Uninstall.cmd` | Removes what was installed and restores what was backed up. |

## What it installs

| Component | Version | Source |
|---|---|---|
| ReShade, add-on edition | 6.8.0 | reshade.me |
| GPosingway | 8.3.1 (release R8.2.1) | github.com/gposingway/gposingway |

Versions, download addresses and SHA-256 checksums are pinned in
[`manifest.json`](manifest.json). Nothing else is downloaded.

## How it works

1. **Locate game.** Reads existing records only; no drive scan. Sources: the
   running game process, XIVLauncher settings, the installed programs list,
   Steam library records, Desktop and Start menu shortcuts, recently run
   programs, and the default install folders. Multiple installs are listed
   with game version and last patch date. A folder can also be browsed for or
   pasted.
2. **Existing files.** Anything that would be replaced is moved to a backup
   folder inside the game folder.
3. **ReShade.** Downloads the official setup file, verifies it, and extracts
   `ReShade64.dll` without running the setup program. It is installed as
   `dxgi.dll`.
4. **GPosingway.** Downloads the release package, verifies it, and inspects
   every entry before unpacking.
5. **Install.** Lists every change and asks for confirmation first.
6. **Verify.** Compares the installed files against the package and confirms
   ReShade is present and unmodified.

## Safeguards

- A system check runs first and stops if the PC cannot run the tool (for
  example, restricted PowerShell on a managed computer).
- Downloads are refused if the size or SHA-256 checksum does not match the
  manifest.
- The package is refused if it contains a program or script, an unexpected
  top-level item, or a path outside the game folder.
- The install stops if GShade is present, the game is running, the game folder
  is not writable, or the folder path is too long for the package.
- A second copy of ReShade under another file name is moved to the backup.
- Only one instance can run at a time.
- If a run fails partway, the tool reports whether the game folder was changed
  and how to restore it.

## Files and locations

| Location | Contents |
|---|---|
| `<game folder>\.openshade-xiv` | Install record and backups |
| `%LOCALAPPDATA%\openshade-xiv` | Downloads and `log.txt` |

## Troubleshooting

- **"Cannot write to the game folder".** Right-click `Install.cmd` and choose
  **Run as administrator**. This is common when the game is in `Program Files`.
- **The script is blocked from running.** Some managed work or school PCs do
  not allow downloaded scripts. The tool cannot run there.
- **No ReShade banner in game.** Run `Check.cmd`, then see GPosingway's
  [troubleshooting guide](https://github.com/gposingway/gposingway/blob/main/md/troubleshooting.md).

## Updating the manifest

When a new ReShade or GPosingway version is adopted:

1. Set the new `version`, `url`, `fileName` and `size`.
2. Set `sha256` to the SHA-256 of the downloaded file. For GPosingway, GitHub
   shows this as the asset digest on the release page.
3. For ReShade, also set `dllSha256` to the SHA-256 of `ReShade64.dll` inside
   the setup file.
4. Run `Preview.cmd`, then a full install into a test folder.

Do not point the manifest at a "latest" address. A pinned version with a
pinned checksum is what makes the download verifiable.

## Disclaimer

- Third-party tools are not permitted by the FINAL FANTASY XIV terms of
  service. Use at your own risk.
- This software is provided "as is", without warranty of any kind. See
  [LICENSE](LICENSE).
- This project is not affiliated with or endorsed by Square Enix, ReShade or
  GPosingway. FINAL FANTASY XIV is a registered trademark of Square Enix
  Holdings Co., Ltd.

## Credits

- **ReShade** by crosire: <https://reshade.me>
- **GPosingway** and its contributors:
  <https://github.com/gposingway/gposingway>. Each shader and preset
  collection it contains has its own licence; see its
  [shader licences](https://github.com/gposingway/gposingway/blob/main/md/shader_licenses.md).
- Maintained by [divinepleroma](https://github.com/divinepleroma).

## Licence

[MIT](LICENSE). This covers only the files in this project.
