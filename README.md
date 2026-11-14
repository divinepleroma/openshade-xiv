# xiv-reshade-walkthrough

A guided setup for **ReShade + GPosingway** on FINAL FANTASY XIV, written so
you can see exactly what it does.

It is a single readable script, not a program. It downloads ReShade and
GPosingway from their official homes, checks each download against a known
fingerprint, shows you what will change in your game folder, and asks before
it changes anything.

This project does not contain or re-upload ReShade, GPosingway, or anyone's
shaders or presets. It only fetches them from where their authors publish them.

## How to use it

1. Download this project (green **Code** button, then **Download ZIP**).
2. Right-click the zip and choose **Extract All**. Do not run the files from
   inside the zip; they need to sit together in a normal folder.
3. Close the game.
4. Double-click **`Preview.cmd`** to see every step without changing anything.
5. Double-click **`Install.cmd`** to do it for real.

Windows may ask whether you want to run a file you downloaded. That is
expected for any downloaded script. You can open every file here in Notepad
first if you want to read it.

When it finishes, start the game and press **Shift+F2** to open the ReShade
menu. **Shift+F3** switches all effects off and on.

| File | What it does |
|---|---|
| `Preview.cmd` | Explains every step. Downloads and changes nothing. |
| `Install.cmd` | Installs, then double-checks its own work. Also repairs an install. |
| `Check.cmd` | Changes nothing. Tells you whether the install is complete and whether ReShade has started with the game. |
| `Uninstall.cmd` | Removes what was installed and restores what was backed up. |

## What it does, step by step

1. **Finds your game**, wherever it is installed. See
   [How it finds your game](#how-it-finds-your-game) below.
2. **Checks what is already there.** If ReShade or shader folders already
   exist, it plans to move them into a backup folder. If GShade is installed
   it stops and asks you to remove that first.
3. **Gets ReShade** from [reshade.me](https://reshade.me), checks the download,
   and takes the one file it needs (`ReShade64.dll`) out of the setup file
   without running the setup program.
4. **Gets GPosingway** from its
   [GitHub releases](https://github.com/gposingway/gposingway/releases), checks
   the download, and inspects every file inside before unpacking.
5. **Shows the full list of changes and asks.** Only then does it move the
   old files to the backup and copy the new ones in.
6. **Double-checks the result.** It compares every installed file against the
   pack and confirms ReShade is in place and unchanged. If anything is off it
   says so, and tells you what to do.

## How it finds your game

It reads a few places that already exist on your PC. It does not scan your
drives, and it changes nothing while looking:

- the game itself, if it happens to be running
- XIVLauncher's settings
- Windows' list of installed programs
- Steam's own records of where its games are, including extra libraries
- Desktop and Start menu shortcuts named after the game
- Windows' record of programs you have run, looking only for FFXIV's
- the default install folders

If it finds more than one copy, it lists them with the game version and the
date each was last patched, so you can tell which one you actually play. If it
finds none, press Enter to browse for `ffxiv_dx11.exe`, or paste the folder.

## Built-in safety checks

Before it starts:

- **A self-check of your PC.** It tests the exact features it relies on (file
  fingerprints, zip archives, secure downloads) and stops with an explanation
  if any does not work, for example on a locked-down work computer.
- **Only one copy runs at a time.**
- **The folder must look like the real game**, not just contain a file with
  the right name.

Before it changes anything:

- It stops if GShade is installed, if the game is running, if Windows will not
  let it write to the folder, or if the game's path is too long for the pack's
  files.
- A second copy of ReShade under a different file name is moved to the backup,
  so two copies cannot clash.
- A download is refused if the website's file is a different size than
  expected, or if its fingerprint does not match.

Afterwards:

- The install double-checks itself (step 6 above).
- `Check.cmd` can repeat that check at any time. It also reads ReShade's own
  log to tell you whether ReShade actually started with the game.
- If something fails halfway, the script says whether your game folder was
  touched and how to put it back.

## What it will never do

- Ask for your password, or for administrator rights. (The one exception: if
  your game lives in `Program Files`, Windows itself may block writing there,
  and the script will tell you how to rerun it as administrator.)
- Install anything that keeps running, starts with Windows, or updates itself.
- Download anything not listed in [`manifest.json`](manifest.json).
- Unpack a pack that contains a program or script, or that tries to write
  outside your game folder.
- Touch your characters, game settings, or any other folder.

## Check it yourself

- [`Walkthrough.ps1`](Walkthrough.ps1) is the entire tool. The `.cmd` files
  only open it.
- [`manifest.json`](manifest.json) lists the two downloads: where they come
  from, which version, and the SHA-256 fingerprint each must match.
- A plain-text log of every run is saved to
  `%LOCALAPPDATA%\xiv-reshade-walkthrough\log.txt`.
- What it installed is recorded in `.xiv-reshade-walkthrough` inside your game
  folder, next to the backups. `Uninstall.cmd` uses that record.

## Good to know

- **Terms of service.** Square Enix does not permit third-party tools. ReShade
  only changes what is drawn on your own screen and is widely used, but using
  it is your decision. Do not discuss it in game chat.
- **Why this ReShade version.** The walkthrough installs one specific ReShade
  version, listed in `manifest.json`, that has been checked with GPosingway.
  It does not grab "the newest", because a version nobody has tested, or a
  file nobody has fingerprinted, is exactly what this tool is meant to avoid.
- **Why the "add-on" edition.** FFXIV needs it for effects that use depth,
  such as depth of field.
- **Size.** GPosingway is about 460 MB to download and the same again unpacked.

## For maintainers

When GPosingway or its supported ReShade version changes, update
`manifest.json`:

1. Set the new `version`, `url`, `fileName` and `size`.
2. Set `sha256` to the SHA-256 of the downloaded file. For GPosingway, GitHub
   shows this as the asset's digest on the release page.
3. For ReShade, also set `dllSha256` to the SHA-256 of `ReShade64.dll` inside
   the setup file.
4. Run `Preview.cmd`, then a real install on a test folder, before publishing.

Never point the manifest at a "latest" link. A pinned version with a pinned
fingerprint is what makes the download checkable.

## Credits

Walkthrough made by [divinepleroma](https://github.com/divinepleroma).

The effects, presets and ReShade itself belong to others:

- **ReShade** by crosire - <https://reshade.me>
- **GPosingway** and its contributors - <https://github.com/gposingway/gposingway>.
  Each shader and preset collection inside it has its own licence; see
  GPosingway's [shader licences](https://github.com/gposingway/gposingway/blob/main/md/shader_licenses.md).

This project is not affiliated with Square Enix, ReShade or GPosingway.

## Licence

The walkthrough script itself is released under the [MIT licence](LICENSE).
That covers only the files in this project. ReShade, GPosingway and every
shader and preset they contain keep their own licences.
