#Requires -Version 5.1
<#
.SYNOPSIS
    A guided, readable setup for ReShade + GPosingway on FINAL FANTASY XIV.

.DESCRIPTION
    This script walks you through installing two things into your game folder:

      1. ReShade      - the program that draws visual effects (https://reshade.me)
      2. GPosingway   - a community pack of effects and presets for FFXIV
                        (https://github.com/gposingway/gposingway)

    It downloads both from their official homes, checks each download against
    the fingerprint listed in manifest.json, and stops if anything differs.
    When it has finished it checks its own work and tells you the result.

    It never installs a background program, and never downloads or runs code
    other than what is listed in manifest.json. Everything it does is in this
    one file, top to bottom.

.PARAMETER DryRun
    Preview mode. Explains every step but downloads and changes nothing.

.PARAMETER Uninstall
    Removes what this walkthrough installed and puts back what it moved aside.

.PARAMETER Check
    Changes nothing. Looks at an existing install and reports whether it is
    complete and whether ReShade has started with the game.

.PARAMETER GamePath
    Skip the search and use this game folder (the one with ffxiv_dx11.exe).

.PARAMETER AssumeYes
    Answer "yes" to every question. Meant for testing, not for normal use.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Check,
    [string]$GamePath,
    [string]$ManifestPath,
    [string]$CacheDir,
    [switch]$AssumeYes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Settings
# ---------------------------------------------------------------------------

$ToolName     = 'xiv-reshade-walkthrough'
$ToolVersion  = '0.2.0'
$GameExe      = 'ffxiv_dx11.exe'
$RecordFolder = '.xiv-reshade-walkthrough'   # created inside the game folder
$StopPrefix   = 'WALKTHROUGH-STOP: '

# File types a shader pack has no reason to contain. If the pack ever
# includes one of these, the walkthrough refuses to unpack it.
$BlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.bat', '.cmd', '.ps1', '.psm1',
    '.vbs', '.js', '.jse', '.wsf', '.hta', '.lnk', '.reg', '.sys', '.jar',
    '.addon', '.addon32', '.addon64'
)

# Other file names ReShade (or GShade) can be installed under.
$OtherInjectorNames = @('d3d11.dll', 'd3d9.dll', 'dinput8.dll', 'opengl32.dll')

# Windows refuses very long file paths in many programs, the game included.
$MaxPathLength = 259

$LocalBase = $env:LOCALAPPDATA
if (-not $LocalBase) { $LocalBase = $env:TEMP }
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot 'manifest.json' }
$AppData = Join-Path $LocalBase $ToolName
if (-not $CacheDir) { $CacheDir = Join-Path $AppData 'downloads' }
$LogPath = Join-Path $AppData 'log.txt'

$script:ExitCode       = 0
$script:ChangesStarted = $false   # true once the game folder is being changed
$script:Mutex          = $null

# ---------------------------------------------------------------------------
#  Small helpers for talking to the player
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $AppData)) {
            New-Item -ItemType Directory -Path $AppData -Force | Out-Null
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($Text) { Write-Log $Text }
}

function Say-Step {
    param([int]$Number, [int]$Of, [string]$Title)
    Write-Host ''
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    Write-Host ("  Step $Number of $Of - $Title") -ForegroundColor Cyan
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    Write-Log "STEP $Number/$Of $Title"
}

function Say-Ok      { param([string]$Text) Say "  [ok] $Text" 'Green' }
function Say-Note    { param([string]$Text) Say "  [!]  $Text" 'Yellow' }
function Say-Bad     { param([string]$Text) Say "  [X]  $Text" 'Red' }
function Say-Preview { param([string]$Text) Say "  [preview] $Text" 'Magenta' }

function Stop-Here {
    param([string]$Text)
    throw ($StopPrefix + $Text)
}

# True when a person is typing answers in a normal window (not a test, and
# not input piped in from a file).
function Test-Interactive {
    if ($AssumeYes) { return $false }
    try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

# Asks a yes/no question. If it gets no usable answer five times in a row
# (for example the window lost its keyboard input), it gives up safely:
# "no" when -DefaultNo is set, otherwise it stops the walkthrough.
function Ask-YesNo {
    param([string]$Question, [switch]$DefaultNo)
    if ($AssumeYes) { Write-Log "ASK (auto-yes): $Question"; return $true }
    for ($try = 1; $try -le 5; $try++) {
        $answer = Read-Host "$Question [Y/N]"
        Write-Log "ASK: $Question -> $answer"
        if ($answer -match '^\s*y') { return $true }
        if ($answer -match '^\s*n') { return $false }
    }
    if ($DefaultNo) { return $false }
    Stop-Here "I didn't get a yes or no, so I stopped to be safe."
}

function Wait-Enter {
    param([string]$Text = 'Press Enter to continue')
    if ($AssumeYes) { return }
    [void](Read-Host $Text)
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# The SHA-256 fingerprint of a file, as 64 hex characters. This uses Windows'
# own hashing directly instead of PowerShell's Get-FileHash command, because
# that command fails to load when Windows PowerShell is started from inside
# a PowerShell 7 window.
function Get-Sha256 {
    param([string]$Path)
    $sha = $null
    try { $sha = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider }
    catch { $sha = [System.Security.Cryptography.SHA256]::Create() }
    $stream = [System.IO.File]::OpenRead($Path)
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# Reads a property that older install records may not have.
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

# ---------------------------------------------------------------------------
#  Checking this PC can run the walkthrough (before anything else happens)
# ---------------------------------------------------------------------------

# Runs a few harmless self-tests of the exact features used later: file
# fingerprints, zip archives and secure downloads. If any of them does not
# behave as expected on this PC, the walkthrough stops before touching anything.
function Test-Environment {
    # These first checks use only basic commands so they still work on
    # locked-down PCs, where the point is to explain why it can't continue.
    if ($env:OS -ne 'Windows_NT') { Stop-Here 'This walkthrough only works on Windows.' }
    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    if ($mode -ne 'FullLanguage') {
        Stop-Here ("This PC limits what PowerShell scripts are allowed to do (mode: $mode). That is common on work or " +
                   "school computers. The walkthrough can't run here, and nothing was changed.")
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Stop-Here 'FINAL FANTASY XIV and this walkthrough need 64-bit Windows. Nothing was changed.'
    }

    $failed = New-Object System.Collections.Generic.List[string]

    # 1. Can it write to its own working folder and fingerprint a file?
    try {
        if (-not (Test-Path -LiteralPath $AppData)) { New-Item -ItemType Directory -Path $AppData -Force | Out-Null }
        $probe = Join-Path $AppData ('selftest-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllBytes($probe, [System.Text.Encoding]::ASCII.GetBytes('xiv-reshade-walkthrough self-test'))
        $hash = Get-Sha256 $probe
        Remove-Item -LiteralPath $probe -Force
        if ($hash -ine 'f84fe38b39a80752f0c0f890db9563337f8cc649beb51ae8a22df74a305f31a8') { throw "unexpected fingerprint $hash" }
    } catch { $failed.Add("file fingerprints ($($_.Exception.Message))") }

    # 2. Can it create and read a zip archive?
    try {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $ms = New-Object System.IO.MemoryStream
        $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $writer = New-Object System.IO.StreamWriter($zip.CreateEntry('folder/test.txt').Open())
        $writer.Write('hello'); $writer.Dispose(); $zip.Dispose()
        $ms.Position = 0
        $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)
        $reader = New-Object System.IO.StreamReader($zip.GetEntry('folder/test.txt').Open())
        $text = $reader.ReadToEnd(); $reader.Dispose(); $zip.Dispose(); $ms.Dispose()
        if ($text -ne 'hello') { throw 'archive did not read back correctly' }
    } catch { $failed.Add("zip archives ($($_.Exception.Message))") }

    # 3. Are secure downloads available?
    try {
        Add-Type -AssemblyName System.Net.Http
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.Http.HttpClient
        $client.Dispose()
    } catch { $failed.Add("secure downloads ($($_.Exception.Message))") }

    try {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Log ("ENV windows={0} powershell={1} edition={2} culture={3} admin={4} interactive={5} script={6}" -f
            [Environment]::OSVersion.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition,
            [System.Globalization.CultureInfo]::CurrentCulture.Name, $admin, (Test-Interactive), $PSScriptRoot)
    } catch { }

    if ($failed.Count -gt 0) {
        Stop-Here ("This PC failed a self-check, so I stopped before doing anything. What didn't work: " +
                   ($failed -join '; ') + ". Nothing was changed. The log is at: $LogPath")
    }
}

# Makes sure only one copy of the walkthrough runs at a time.
function Enter-SingleInstance {
    try {
        $created = $false
        $script:Mutex = [System.Threading.Mutex]::new($true, "Local\$ToolName", [ref]$created)
        if (-not $created) {
            $script:Mutex.Dispose(); $script:Mutex = $null
            Stop-Here 'The walkthrough is already open in another window. Finish or close that one first.'
        }
    } catch {
        if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw }
    }
}

# ---------------------------------------------------------------------------
#  Finding the game
# ---------------------------------------------------------------------------

# Returns the folder that contains ffxiv_dx11.exe, or $null. Accepts the
# game folder itself, the folder above it, the "boot" folder next to it,
# or the path of a program inside any of those.
function Resolve-GameFolder {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $p = $Path.Trim().Trim('"').Trim()
        if (-not $p) { return $null }
        if ($p -match '\.exe$') { $p = Split-Path $p -Parent }
        $p = $p.TrimEnd('\')
        $candidates = New-Object System.Collections.Generic.List[string]
        $candidates.Add($p)
        $candidates.Add((Join-Path $p 'game'))
        if ((Split-Path $p -Leaf) -ieq 'boot') { $candidates.Add((Join-Path (Split-Path $p -Parent) 'game')) }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath (Join-Path $candidate $GameExe) -PathType Leaf) {
                return (Get-Item -LiteralPath $candidate).FullName.TrimEnd('\')
            }
        }
    } catch { }
    return $null
}

# A few facts about a game folder, used to describe it and to sanity-check it.
function Get-GameInfo {
    param([string]$Folder)
    $version = ''
    try {
        $verFile = Join-Path $Folder 'ffxivgame.ver'
        if (Test-Path -LiteralPath $verFile) { $version = ([string](Get-Content -LiteralPath $verFile -TotalCount 1)).Trim() }
    } catch { }
    $complete = (Test-Path -LiteralPath (Join-Path $Folder 'sqpack') -PathType Container) -or ($version -ne '')
    $updated = $null
    try { $updated = (Get-Item -LiteralPath (Join-Path $Folder $GameExe)).LastWriteTime } catch { }
    return [pscustomobject]@{ Version = $version; LooksComplete = $complete; Updated = $updated }
}

function Format-GameLine {
    param([string]$Folder, [string]$Source)
    $info = Get-GameInfo $Folder
    $bits = New-Object System.Collections.Generic.List[string]
    if ($info.Version) { $bits.Add("game version $($info.Version)") }
    if ($info.Updated) { $bits.Add("last patched $($info.Updated.ToString('yyyy-MM-dd'))") }
    if ($Source)       { $bits.Add("found via $Source") }
    if ($bits.Count -eq 0) { return $Folder }
    return ('{0}   ({1})' -f $Folder, ($bits -join ', '))
}

# Looks for the game. Every source here is read-only and already on this PC:
# nothing is scanned across your drives, and nothing is changed.
function Find-GameFolders {
    $places = New-Object System.Collections.Generic.List[object]
    function Add-Place { param($List, [string]$Path, [string]$Source)
        if ($Path) { $List.Add([pscustomobject]@{ Path = $Path; Source = $Source }) }
    }

    # 1. If the game is running right now, Windows knows exactly where it is.
    try {
        foreach ($proc in @(Get-Process -Name 'ffxiv_dx11' -ErrorAction SilentlyContinue)) {
            $procPath = $null
            try { $procPath = $proc.Path } catch { }
            Add-Place $places $procPath 'the game that is running right now'
        }
    } catch { }

    # 2. XIVLauncher remembers where the game is.
    try {
        if ($env:APPDATA) {
            $cfg = Join-Path $env:APPDATA 'XIVLauncher\launcherConfigV3.json'
            if (Test-Path -LiteralPath $cfg) {
                $json = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
                Add-Place $places ([string](Get-Prop $json 'GamePath' '')) 'XIVLauncher settings'
            }
            Add-Place $places (Join-Path $env:APPDATA 'XIVLauncher\ffxiv') 'XIVLauncher folder'
        }
    } catch { }

    # 3. The official installer registers itself with Windows.
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            foreach ($item in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
                $name = [string](Get-Prop $item 'DisplayName' '')
                if ($name -like 'FINAL FANTASY XIV*') {
                    Add-Place $places ([string](Get-Prop $item 'InstallLocation' '')) "Windows' list of installed programs"
                }
            }
        } catch { }
    }

    # 4. Steam libraries (39210 is FFXIV, 312060 is the free trial).
    try {
        $steamRoots = New-Object System.Collections.Generic.List[string]
        $steam = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        $steamPath = [string](Get-Prop $steam 'SteamPath' '')
        if ($steamPath) { $steamRoots.Add($steamPath.Replace('/', '\')) }
        foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if ($pf) { $steamRoots.Add((Join-Path $pf 'Steam')) }
        }
        $libraries = New-Object System.Collections.Generic.List[string]
        foreach ($root in $steamRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            $libraries.Add($root)
            $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf) {
                $text = Get-Content -LiteralPath $vdf -Raw
                foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                    $libraries.Add($m.Groups[1].Value.Replace('\\', '\'))
                }
            }
        }
        foreach ($lib in $libraries) {
            foreach ($appId in @('39210', '312060')) {
                $acf = Join-Path $lib "steamapps\appmanifest_$appId.acf"
                if (Test-Path -LiteralPath $acf) {
                    $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
                    if ($m.Success) { Add-Place $places (Join-Path $lib ('steamapps\common\' + $m.Groups[1].Value)) 'Steam' }
                }
            }
            Add-Place $places (Join-Path $lib 'steamapps\common\FINAL FANTASY XIV Online') 'Steam'
            Add-Place $places (Join-Path $lib 'steamapps\common\FINAL FANTASY XIV - A Realm Reborn') 'Steam'
        }
    } catch { }

    # 5. Desktop and Start menu shortcuts named after the game.
    try {
        $shortcutFolders = @(
            @{ Path = [Environment]::GetFolderPath('Desktop');                Deep = $false },
            @{ Path = [Environment]::GetFolderPath('CommonDesktopDirectory'); Deep = $false },
            @{ Path = [Environment]::GetFolderPath('Programs');               Deep = $true },
            @{ Path = [Environment]::GetFolderPath('CommonPrograms');         Deep = $true }
        )
        $shell = $null
        foreach ($folder in $shortcutFolders) {
            if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }
            $links = @(Get-ChildItem -LiteralPath $folder.Path -Filter '*.lnk' -File -Recurse:([bool]$folder.Deep) -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'FINAL FANTASY XIV|FFXIV' })
            foreach ($link in $links) {
                if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                # CreateShortcut on an existing shortcut only reads it.
                Add-Place $places ([string]$shell.CreateShortcut($link.FullName).TargetPath) 'a shortcut'
            }
        }
    } catch { }

    # 6. Windows keeps a list of programs you have run. Look only for FFXIV's.
    $historyKeys = @(
        'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache',
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store'
    )
    foreach ($key in $historyKeys) {
        try {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            foreach ($valueName in (Get-Item -LiteralPath $key).GetValueNames()) {
                $m = [regex]::Match($valueName, '^(?<p>[A-Za-z]:\\.*?\\ffxiv(_dx11|boot|boot64|launcher|launcher64)?\.exe)', 'IgnoreCase')
                if ($m.Success) { Add-Place $places $m.Groups['p'].Value "Windows' record of programs you have run" }
            }
        } catch { }
    }

    # 7. Default install folders on every drive.
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName
            foreach ($sub in @('Program Files (x86)\SquareEnix', 'Program Files\SquareEnix', 'SquareEnix', 'Games\SquareEnix', 'Games')) {
                Add-Place $places (Join-Path $root "$sub\FINAL FANTASY XIV - A Realm Reborn") 'the default install folder'
            }
        }
    } catch { }

    $found = New-Object System.Collections.Generic.List[object]
    $seen  = New-Object System.Collections.Generic.List[string]
    foreach ($place in $places) {
        $resolved = Resolve-GameFolder $place.Path
        if ($resolved -and -not ($seen -contains $resolved)) {
            $seen.Add($resolved)
            $found.Add([pscustomobject]@{ Path = $resolved; Source = $place.Source })
        }
    }
    return $found.ToArray()
}

# Opens the normal Windows "pick a file" window so the player can point at
# ffxiv_dx11.exe instead of typing a path. Returns $null if cancelled.
function Show-GamePicker {
    $owner = $null; $dialog = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Find $GameExe inside your FINAL FANTASY XIV 'game' folder"
        $dialog.Filter = "FINAL FANTASY XIV ($GameExe)|$GameExe"
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return [string]$dialog.FileName }
    } catch {
        Write-Log "File picker unavailable: $($_.Exception.Message)"
    } finally {
        if ($dialog) { $dialog.Dispose() }
        if ($owner)  { $owner.Dispose() }
    }
    return $null
}

function Select-GameFolder {
    if ($GamePath) {
        $resolved = Resolve-GameFolder $GamePath
        if (-not $resolved) { Stop-Here "I couldn't find $GameExe in: $GamePath" }
        return $resolved
    }

    Say '  Looking for your game (this only reads, it changes nothing)...'
    $found = @(Find-GameFolders)

    if ($found.Count -eq 1) {
        Say-Ok ('Found it: ' + (Format-GameLine $found[0].Path $found[0].Source))
        if (Ask-YesNo '  Is this the right game folder?') { return $found[0].Path }
    } elseif ($found.Count -gt 1) {
        Say '  I found more than one copy of the game:'
        for ($i = 0; $i -lt $found.Count; $i++) {
            Say ("    {0}. {1}" -f ($i + 1), (Format-GameLine $found[$i].Path $found[$i].Source)) 'White'
        }
        Say '  If you are not sure, the one patched most recently is usually the one you play.'
        if ($AssumeYes) { return $found[0].Path }
        for ($try = 1; $try -le 5; $try++) {
            $pick = Read-Host "  Type the number of the one you play (or press Enter to choose a different folder)"
            if (-not $pick) { break }
            $n = 0
            if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) { return $found[$n - 1].Path }
        }
    } else {
        Say-Note "I couldn't find the game on my own. That's fine."
    }

    if ($AssumeYes) { Stop-Here 'No game folder found. Pass -GamePath to say where it is.' }
    $canBrowse = Test-Interactive
    Say ''
    Say '  Your game folder usually ends in:'
    Say '    ...\FINAL FANTASY XIV - A Realm Reborn\game' 'White'
    if ($canBrowse) {
        Say "  Press Enter to browse for $GameExe, or paste the folder path here."
    } else {
        Say '  Open it in File Explorer, click the address bar, copy the path and paste it here.'
    }
    for ($try = 1; $try -le 8; $try++) {
        $typed = Read-Host '  Game folder (or Q to quit)'
        if ($typed -match '^\s*q\s*$') { Stop-Here 'No changes were made.' }
        if (-not $typed -and $canBrowse) { $typed = Show-GamePicker }
        $resolved = Resolve-GameFolder $typed
        if ($resolved) { return $resolved }
        Say-Note "I couldn't find $GameExe there. Try again."
    }
    Stop-Here "I couldn't find the game folder. No changes were made."
}

# A last sanity check on the chosen folder before anything is planned for it.
function Confirm-GameFolder {
    param([string]$Game)
    $info = Get-GameInfo $Game
    if (-not $info.LooksComplete) {
        Say-Note "This folder has $GameExe but is missing the rest of the game's files,"
        Say '       so it may be a copy, a leftover, or the wrong folder.'
        if (-not (Ask-YesNo '  Use it anyway?')) { Stop-Here 'No changes were made.' }
    }
}

# ---------------------------------------------------------------------------
#  Downloading and checking files
# ---------------------------------------------------------------------------

function Test-Fingerprint {
    param([string]$Path, [string]$ExpectedSha256)
    $actual = Get-Sha256 $Path
    Write-Log "SHA256 $Path = $actual (expected $ExpectedSha256)"
    return ($actual -ieq $ExpectedSha256)
}

function Save-Download {
    param([string]$Url, [string]$Destination, [string]$Label, [long]$ExpectedSize)
    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $part = "$Destination.part"
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(3)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("$ToolName/$ToolVersion")
    $response = $null; $inStream = $null; $outStream = $null
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            Stop-Here ("The website answered with an error ($([int]$response.StatusCode)) when I asked for $Label. " +
                       'The file has probably moved, which means this walkthrough needs an update. Nothing in your game was changed.')
        }
        $total = $response.Content.Headers.ContentLength
        if ($ExpectedSize -and $total -and $total -ne $ExpectedSize) {
            Stop-Here ("The file on the website for $Label is a different size than this walkthrough expects " +
                       "($total bytes, expected $ExpectedSize). It has probably been updated, so I did not download it. " +
                       'Check for a newer version of this walkthrough. Nothing in your game was changed.')
        }
        $inStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [System.IO.File]::Create($part)
        $buffer = New-Object byte[] (1MB)
        $done = [long]0
        $lastShown = [DateTime]::MinValue
        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $done += $read
            if (([DateTime]::Now - $lastShown).TotalMilliseconds -gt 400) {
                $lastShown = [DateTime]::Now
                if ($total) {
                    $pct = [int](100 * $done / $total)
                    Write-Progress -Activity "Downloading $Label" -Status ("{0} of {1}" -f (Format-Size $done), (Format-Size $total)) -PercentComplete $pct
                } else {
                    Write-Progress -Activity "Downloading $Label" -Status (Format-Size $done)
                }
            }
        }
    } finally {
        Write-Progress -Activity "Downloading $Label" -Completed
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
        if ($response)  { $response.Dispose() }
        $client.Dispose()
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
}

# Returns the path of a downloaded file whose fingerprint matches the
# manifest. Reuses an earlier download if it is still intact.
function Get-CheckedDownload {
    param($Asset)
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $target = Join-Path $CacheDir $Asset.fileName

    if (Test-Path -LiteralPath $target) {
        Say '  You already have this download. Checking it is intact...'
        if (Test-Fingerprint $target $Asset.sha256) {
            Say-Ok 'It matches the published fingerprint. No need to download again.'
            return $target
        }
        Say-Note 'The earlier download is incomplete or different. Fetching a fresh copy.'
        Remove-Item -LiteralPath $target -Force
    }

    try {
        $free = (Get-Item -LiteralPath $CacheDir).PSDrive.Free
        if ($free -and $free -lt ([long]$Asset.size + 50MB)) {
            Stop-Here ("There isn't enough free space to download $($Asset.name): it needs $(Format-Size $Asset.size) and " +
                       "the drive has $(Format-Size $free) free. Free up some space and run this again. Nothing in your game was changed.")
        }
    } catch { if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw } }

    $siteName = ([System.Uri]$Asset.url).Host
    Say "  Downloading from: $($Asset.url)"
    for ($attempt = 1; ; $attempt++) {
        try {
            Save-Download -Url $Asset.url -Destination $target -Label $Asset.name -ExpectedSize $Asset.size
            break
        } catch {
            if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw }
            Write-Log ("Download attempt $attempt failed: " + ($_ | Out-String))
            Remove-Item -LiteralPath "$target.part" -Force -ErrorAction SilentlyContinue
            Say-Note "The download from $siteName didn't finish."
            if ($attempt -ge 3 -or -not (Ask-YesNo -DefaultNo '  Try again?')) {
                Stop-Here ("I couldn't download $($Asset.name) from $siteName. Check your internet connection, and any VPN, " +
                           'firewall or antivirus that might be blocking it, then run this again. Nothing in your game was changed.')
            }
        }
    }

    Say '  Checking the download against its published fingerprint...'
    if (-not (Test-Fingerprint $target $Asset.sha256)) {
        Remove-Item -LiteralPath $target -Force
        Stop-Here ("The file I downloaded for $($Asset.name) does not match the fingerprint in manifest.json. " +
                   "I deleted it and changed nothing in your game. This usually means the download was cut short, " +
                   "or the file on the website changed. Try again later, or check for a newer version of this walkthrough.")
    }
    Say-Ok 'The download matches. It is the exact file this walkthrough expects.'
    return $target
}

# ReShade's setup program is a small program with a zip archive attached to
# its end. This reads that archive and pulls out one file, without running
# the setup program at all.
function Export-ReShadeDll {
    param([string]$SetupPath, [string]$EntryName, [string]$OutPath)
    Add-Type -AssemblyName System.IO.Compression
    $bytes = [System.IO.File]::ReadAllBytes($SetupPath)

    $starts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -le $bytes.Length - 4; $i += 512) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and $bytes[$i + 2] -eq 0x03 -and $bytes[$i + 3] -eq 0x04) { $starts.Add($i) }
    }

    foreach ($start in $starts) {
        $stream = $null; $zip = $null
        try {
            $stream = [System.IO.MemoryStream]::new($bytes, $start, $bytes.Length - $start, $false)
            $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
            $entry = $zip.GetEntry($EntryName)
            if ($entry) {
                $in = $entry.Open()
                $out = [System.IO.File]::Create($OutPath)
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
                return $true
            }
        } catch {
            Write-Log "Archive attempt at offset $start failed: $($_.Exception.Message)"
        } finally {
            if ($zip) { $zip.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    return $false
}

# Works with the effects pack in one of three ways:
#   -Mode Inspect : check every entry, write nothing, report what is inside
#   -Mode Unpack  : check every entry, then unpack
#   -Mode Verify  : compare what is in the game folder against the pack
# In every mode each entry is checked BEFORE anything is written:
#   - it must land inside the game folder,
#   - it must be inside one of the folders/files the manifest allows,
#   - it must not be a program or script,
#   - its full path must be short enough for Windows.
function Invoke-Pack {
    param([string]$ZipPath, [string]$Destination, [string[]]$AllowedTopLevel,
          [ValidateSet('Inspect', 'Unpack', 'Verify')][string]$Mode)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $plan = New-Object System.Collections.Generic.List[object]
        $bytes = [long]0
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            if (-not $relative) { continue }
            $top = $relative.Split('\')[0]
            if ($AllowedTopLevel -notcontains $top) {
                Stop-Here "The pack contains something unexpected ('$top'). I stopped before unpacking anything."
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Here "The pack tried to place a file outside your game folder ('$relative'). I stopped before unpacking anything."
            }
            $isFolder = $relative.EndsWith('\')
            if (-not $isFolder) {
                $ext = [System.IO.Path]::GetExtension($relative).ToLowerInvariant()
                if ($BlockedExtensions -contains $ext) {
                    Stop-Here "The pack contains a program or script ('$relative'). Effect packs should not. I stopped before unpacking anything."
                }
                $bytes += $entry.Length
            }
            if ($target.Length -gt $MaxPathLength) {
                Stop-Here ("Your game folder's path is too long for some of the pack's files (Windows allows about 260 " +
                           "characters, and '$relative' would need $($target.Length)). Moving the game to a shorter path " +
                           'would fix it. I stopped before unpacking anything.')
            }
            $plan.Add([pscustomobject]@{ Entry = $entry; Target = $target; IsFolder = $isFolder; Relative = $relative })
        }

        $files = @($plan | Where-Object { -not $_.IsFolder })
        $result = [pscustomobject]@{ Files = $files.Count; Bytes = $bytes; Problems = @() }
        if ($Mode -eq 'Inspect') { return $result }

        if ($Mode -eq 'Verify') {
            $problems = New-Object System.Collections.Generic.List[string]
            foreach ($item in $files) {
                if (-not (Test-Path -LiteralPath $item.Target -PathType Leaf)) { $problems.Add("missing: $($item.Relative)") }
                elseif ((Get-Item -LiteralPath $item.Target).Length -ne $item.Entry.Length) { $problems.Add("wrong size: $($item.Relative)") }
            }
            $result.Problems = @($problems.ToArray())
            return $result
        }

        $n = 0
        foreach ($item in $plan) {
            if ($item.IsFolder) {
                [void][System.IO.Directory]::CreateDirectory($item.Target)
                continue
            }
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($item.Target))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.Target, $true)
            $n++
            if ($n % 40 -eq 0) {
                Write-Progress -Activity 'Unpacking effects and presets' -Status "$n of $($files.Count) files" -PercentComplete ([int](100 * $n / $files.Count))
            }
        }
        Write-Progress -Activity 'Unpacking effects and presets' -Completed
        return $result
    } finally {
        $zip.Dispose()
    }
}

# ---------------------------------------------------------------------------
#  Looking at what is already in the game folder
# ---------------------------------------------------------------------------

function Get-ProductName {
    param([string]$Path)
    try { return [string][System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductName } catch { return '' }
}

function Test-CanWrite {
    param([string]$Folder)
    $probe = Join-Path $Folder ("$ToolName-write-test-" + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# True if a copy of the game started from this folder is running. If Windows
# won't say where a running copy was started from, assume it is this one.
function Test-GameRunning {
    param([string]$GameFolder)
    $root = $GameFolder.TrimEnd('\') + '\'
    foreach ($proc in @(Get-Process -Name 'ffxiv_dx11' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $proc.Path } catch { }
        if (-not $path) { return $true }
        if ($path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Wait-GameClosed {
    param([string]$GameFolder)
    $tries = 0
    while (Test-GameRunning $GameFolder) {
        Say-Note 'The game is running. Please close it completely first.'
        if ($DryRun) { Say '       (Preview mode, so I will carry on.)'; return }
        $tries++
        if ($AssumeYes -or $tries -gt 10) { Stop-Here 'The game is running. Close it and run this again.' }
        Wait-Enter '  Press Enter once the game is closed'
    }
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Stop-Here ("I can't find manifest.json next to this script. If you opened this from inside a zip file, " +
                   'extract the whole folder first (right-click the zip, "Extract All"), then run it from there.')
    }
    try { $m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json }
    catch { Stop-Here 'manifest.json is damaged and cannot be read. Download a fresh copy of this walkthrough.' }
    foreach ($hash in @((Get-Prop (Get-Prop $m 'reshade') 'sha256' ''), (Get-Prop (Get-Prop $m 'reshade') 'dllSha256' ''),
                        (Get-Prop (Get-Prop $m 'gposingway') 'sha256' ''))) {
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') {
            Stop-Here 'manifest.json is missing a fingerprint, so I cannot check downloads. Get a complete copy of this walkthrough.'
        }
    }
    foreach ($url in @($m.reshade.url, $m.gposingway.url)) {
        if ($url -notmatch '^https?://') { Stop-Here 'manifest.json has a download address I do not recognise. Get a fresh copy of this walkthrough.' }
    }
    return $m
}

function Get-Record {
    param([string]$GameFolder)
    $path = Join-Path (Join-Path $GameFolder $RecordFolder) 'install-record.json'
    if (Test-Path -LiteralPath $path) {
        try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { Write-Log "Record unreadable: $($_.Exception.Message)" }
    }
    return $null
}

# What ReShade itself wrote the last time it started with the game.
function Get-ReShadeLogInfo {
    param([string]$Game)
    try {
        $log = Join-Path $Game 'ReShade.log'
        if (-not (Test-Path -LiteralPath $log)) { return $null }
        $version = ''
        foreach ($line in @(Get-Content -LiteralPath $log -TotalCount 40 -ErrorAction SilentlyContinue)) {
            if ($line -match "ReShade version '([^']+)'") { $version = $Matches[1]; break }
        }
        return [pscustomobject]@{ When = (Get-Item -LiteralPath $log).LastWriteTime; Version = $version }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
#  Checking an install is complete
# ---------------------------------------------------------------------------

# Returns a list of checks, each with a name, pass/fail, and what to do about
# a failure. With -PackZip it compares every file against the pack itself.
function Get-InstallChecks {
    param([string]$Game, $Record, [string]$PackZip)
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check { param($List, [string]$Name, [bool]$Ok, [string]$Advice = '')
        $List.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Advice = $Advice })
    }
    $rerun = 'Run Install.cmd again to repair it.'
    $antivirus = 'Security software sometimes removes or blocks this file. Run Install.cmd again; if it disappears again, ' +
                 'allow the game folder in your antivirus.'

    Add-Check $checks "The game is still where it was ($GameExe)" (Test-Path -LiteralPath (Join-Path $Game $GameExe) -PathType Leaf) `
        'The game folder has moved or been removed. Run Install.cmd and choose the new location.'

    $reshadeFile = [string](Get-Prop $Record 'reshadeFile' 'dxgi.dll')
    $dll = Join-Path $Game $reshadeFile
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        Add-Check $checks "ReShade is in place ($reshadeFile)" $false $antivirus
    } else {
        $version = [string](Get-Prop $Record 'reshadeVersion' '')
        Add-Check $checks "ReShade $version is in place and unchanged ($reshadeFile)" (Test-Fingerprint $dll ([string](Get-Prop $Record 'reshadeSha256' ''))) `
            ('The file is there but is not the one this walkthrough installed. Another tool may have replaced it. ' + $rerun)
    }

    $packItems = @(Get-Prop $Record 'packItems' @())
    $missing = @($packItems | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Game $_)) })
    Add-Check $checks 'The effects and presets folders are there' ($missing.Count -eq 0) ("Missing: $($missing -join ', '). " + $rerun)

    if ($PackZip) {
        $verify = Invoke-Pack -ZipPath $PackZip -Destination $Game -AllowedTopLevel $packItems -Mode Verify
        foreach ($p in @($verify.Problems | Select-Object -First 20)) { Write-Log "VERIFY $p" }
        Add-Check $checks "Every file from the pack arrived intact ($($verify.Files) files)" ($verify.Problems.Count -eq 0) `
            ("$($verify.Problems.Count) file(s) are missing or the wrong size (listed in the log). " + $rerun)
    } else {
        $expected = [int](Get-Prop $Record 'packFileCount' 0)
        if ($expected -gt 0 -and $missing.Count -eq 0) {
            $present = 0
            foreach ($name in $packItems) {
                $path = Join-Path $Game $name
                if (Test-Path -LiteralPath $path -PathType Container) {
                    $present += @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue).Count
                } elseif (Test-Path -LiteralPath $path) { $present++ }
            }
            Add-Check $checks "The pack's files are all there ($present found, $expected installed)" ($present -ge $expected) `
                ("$($expected - $present) file(s) have gone missing since the install. " + $rerun)
        }
    }

    $ini = Join-Path $Game 'ReShade.ini'
    if ($packItems -contains 'ReShade.ini') {
        $pointsAtPack = $false
        try {
            if (Test-Path -LiteralPath $ini) {
                $pointsAtPack = [bool](Select-String -LiteralPath $ini -Pattern '^EffectSearchPaths=.*reshade-shaders' -Quiet)
            }
        } catch { }
        Add-Check $checks 'ReShade is set up to use the installed effects' $pointsAtPack `
            ('ReShade.ini is missing or points somewhere else, so presets may show no effects. ' + $rerun)
    }
    return $checks.ToArray()
}

# Prints the checks and returns how many failed.
function Show-Checks {
    param($Checks)
    $failed = 0
    foreach ($c in $Checks) {
        if ($c.Ok) { Say-Ok $c.Name }
        else {
            $failed++
            Say-Bad $c.Name
            if ($c.Advice) { Say "       $($c.Advice)" }
        }
    }
    return $failed
}

# ---------------------------------------------------------------------------
#  The install walkthrough
# ---------------------------------------------------------------------------

function Start-Install {
    $m = Read-Manifest
    $steps = 6

    Say ''
    Say '  ReShade + GPosingway setup for FINAL FANTASY XIV' 'White'
    Say "  $ToolName $ToolVersion"
    if ($DryRun) { Say '  PREVIEW MODE: nothing will be downloaded or changed.' 'Magenta' }
    Say-Ok 'Self-check passed: this PC can run the walkthrough.'
    Say ''
    Say '  This will add screen effects (colour, lighting, depth of field) to'
    Say '  your game by installing two free community tools:'
    Say ''
    Say "    ReShade $($m.reshade.version)   the program that draws the effects" 'White'
    Say "      $($m.reshade.homepage)"
    Say "    GPosingway $($m.gposingway.version)   effects and presets made for FFXIV" 'White'
    Say "      $($m.gposingway.homepage)"
    Say ''
    Say '  What I will do:'
    Say '    - download both from their official websites'
    Say '    - check each download is exactly the file this walkthrough expects'
    Say '    - move anything I would replace into a backup folder first'
    Say '    - copy the files into your game folder, then check my own work'
    Say '  What I will not do:'
    Say '    - ask for administrator rights or your password'
    Say '    - install anything that keeps running or updates itself'
    Say '    - touch your characters, settings, or anything outside the game folder'
    Say ''
    Say '  One honest note: Square Enix does not allow third-party tools.'
    Say '  ReShade only changes what is drawn on your own screen, and many'
    Say '  players use it, but using it is your decision. Do not mention it'
    Say '  in game chat.'
    Say ''
    if (-not (Ask-YesNo '  Ready to start?')) { Stop-Here 'No changes were made.' }

    # --- Step 1 -----------------------------------------------------------
    Say-Step 1 $steps 'Find your game'
    $game = Select-GameFolder
    Confirm-GameFolder $game
    Say-Ok "Using: $game"
    Wait-GameClosed $game

    # --- Step 2 -----------------------------------------------------------
    Say-Step 2 $steps "Check what's already there"
    $dxgi        = Join-Path $game $m.reshade.installAs
    $recordDir   = Join-Path $game $RecordFolder
    $stamp       = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $backupDir   = Join-Path (Join-Path $recordDir 'backup') $stamp
    $toBackUp    = New-Object System.Collections.Generic.List[string]
    $reshadeDone = $false

    # If this walkthrough was used here before, remember what was in the
    # folder BEFORE that first install, so Uninstall still restores that.
    $prev         = Get-Record $game
    $origBackup   = $null      # where the pre-install files were put
    $origNames    = @()        # which pre-install files are in there
    $oursAlready  = @()        # things a previous run of this tool installed
    if ($prev) {
        if ($prev.backupFolder) { $origBackup = [string]$prev.backupFolder }
        $origNames   = @($prev.backedUp)
        $oursAlready = @($prev.packItems)
        if ($prev.reshadeInstalled) { $oursAlready += [string]$prev.reshadeFile }
        if (Get-Prop $prev 'completed' $true) { Say "  This walkthrough was used here before, so I'll refresh that install." }
        else { Say-Note "An earlier run here did not finish. I'll redo it from the start." }
    }

    $gshadeFiles = @(@($m.reshade.installAs) + $OtherInjectorNames | Where-Object {
        (Test-Path -LiteralPath (Join-Path $game $_)) -and ((Get-ProductName (Join-Path $game $_)) -like '*GShade*') })
    if ((Test-Path -LiteralPath (Join-Path $game 'GShade.ini')) -or $gshadeFiles.Count -gt 0) {
        Stop-Here ('GShade is installed in this game folder. Please remove it with its own uninstaller first ' +
                   '(Windows Settings > Apps > GShade), then run this again. I changed nothing.')
    }

    if (Test-Path -LiteralPath $dxgi) {
        if (Test-Fingerprint $dxgi $m.reshade.dllSha256) {
            Say-Ok "ReShade $($m.reshade.version) is already installed. I'll leave it as it is."
            $reshadeDone = $true
        } else {
            $product = Get-ProductName $dxgi
            if ($product -like '*ReShade*') {
                Say "  A different version of ReShade is installed. I'll back it up and"
                Say "  replace it with $($m.reshade.version), the version GPosingway is built for."
            } else {
                Say-Note "There is a file called $($m.reshade.installAs) here that isn't ReShade"
                Say "       (it says it is: '$product'). Another tool may have put it there."
                if (-not (Ask-YesNo '  Move it to the backup folder and continue?')) { Stop-Here 'No changes were made.' }
            }
            $toBackUp.Add($m.reshade.installAs)
        }
    } else {
        Say '  ReShade is not installed yet.'
    }

    # A second copy of ReShade under another file name would load twice.
    foreach ($name in $OtherInjectorNames) {
        $other = Join-Path $game $name
        if ((Test-Path -LiteralPath $other) -and ((Get-ProductName $other) -like '*ReShade*')) {
            Say-Note "ReShade is also installed here under another name ($name). Two copies"
            Say '       would clash, so I will move that one to the backup folder too.'
            $toBackUp.Add($name)
        }
    }

    foreach ($name in $m.gposingway.allowedTopLevel) {
        if (Test-Path -LiteralPath (Join-Path $game $name)) { $toBackUp.Add($name) }
    }
    if ($toBackUp.Count -gt 0) {
        Say '  These already exist, so I will move them to a backup folder first:'
        foreach ($name in $toBackUp) { Say "    $name" 'White' }
        Say "  Backups are kept in: $(Join-Path $recordDir 'backup')"
    } else {
        Say-Ok 'Nothing here needs backing up.'
    }

    if (-not $DryRun) {
        if (-not (Test-CanWrite $game)) {
            Stop-Here ('Windows is not letting me write to the game folder. This is common when the game is in ' +
                       '"Program Files", or when security software protects the folder. Close this window, right-click ' +
                       'Install.cmd, choose "Run as administrator", and start again. I changed nothing.')
        }
        try {
            $free = (Get-Item -LiteralPath $game).PSDrive.Free
            $need = [long]$m.gposingway.size * 2 + 100MB
            if ($free -and $free -lt $need) {
                Say-Note ("You have {0} free on this drive and this needs about {1}." -f (Format-Size $free), (Format-Size $need))
                if (-not (Ask-YesNo '  Continue anyway?')) { Stop-Here 'No changes were made.' }
            }
        } catch { if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw } }
    }

    # --- Step 3 -----------------------------------------------------------
    Say-Step 3 $steps 'Get ReShade'
    Say '  ReShade is the program that applies effects to the picture. FFXIV'
    Say '  needs the "add-on" edition, which lets effects see how far away'
    Say '  things are (needed for depth of field and similar effects).'
    Say "  Official site: $($m.reshade.homepage)"
    Say ''
    $reshadeDll = $null
    if ($reshadeDone) {
        Say-Ok 'Already installed and matching. Skipping this step.'
    } elseif ($DryRun) {
        Say-Preview "Would download $($m.reshade.fileName) ($(Format-Size $m.reshade.size)) from $($m.reshade.url)"
        Say-Preview "Would check it, take $($m.reshade.dllEntry) out of it, and check that too."
    } else {
        $setup = Get-CheckedDownload $m.reshade
        Say "  Taking $($m.reshade.dllEntry) out of the setup file (without running it)..."
        $reshadeDll = Join-Path $CacheDir ("ReShade64-$($m.reshade.version).dll")
        if (-not (Export-ReShadeDll -SetupPath $setup -EntryName $m.reshade.dllEntry -OutPath $reshadeDll)) {
            Stop-Here "I couldn't find $($m.reshade.dllEntry) inside the ReShade setup file. I changed nothing in your game."
        }
        if (-not (Test-Fingerprint $reshadeDll $m.reshade.dllSha256)) {
            Remove-Item -LiteralPath $reshadeDll -Force
            Stop-Here 'The ReShade file I extracted does not match the fingerprint in manifest.json. I changed nothing in your game.'
        }
        Say-Ok 'ReShade is ready and verified.'
    }

    # --- Step 4 -----------------------------------------------------------
    Say-Step 4 $steps 'Get GPosingway'
    Say '  GPosingway is a pack of effects and ready-made looks ("presets")'
    Say '  collected by the FFXIV community, set up so they work together.'
    Say "  Official site: $($m.gposingway.homepage)"
    Say "  It is a big download: $(Format-Size $m.gposingway.size)."
    Say ''
    $pack = $null
    $inside = $null
    if ($DryRun) {
        Say-Preview "Would download $($m.gposingway.fileName) from $($m.gposingway.url)"
        Say-Preview 'Would check it, then check every file inside before unpacking.'
    } else {
        $pack = Get-CheckedDownload $m.gposingway
        Say '  Checking what is inside the pack before unpacking...'
        $inside = Invoke-Pack -ZipPath $pack -Destination $game -AllowedTopLevel $m.gposingway.allowedTopLevel -Mode Inspect
        Say-Ok "$($inside.Files) files, all effects, images and settings. No programs or scripts."
    }

    # --- Step 5 -----------------------------------------------------------
    Say-Step 5 $steps 'Install into your game folder'
    Say '  Here is exactly what will change in:'
    Say "    $game" 'White'
    foreach ($name in $toBackUp) { Say "    move    $name  ->  backup folder" }
    if (-not $reshadeDone) { Say "    add     $($m.reshade.installAs)  (this is ReShade)" }
    foreach ($name in $m.gposingway.allowedTopLevel) { Say "    add     $name" }
    Say ''
    if ($DryRun) {
        Say-Preview 'Preview finished. Nothing was downloaded or changed.'
        Say '  Run Install.cmd when you are ready to do it for real.'
        return
    }
    if (-not (Ask-YesNo '  Go ahead?')) { Stop-Here 'No changes were made to your game.' }
    Wait-GameClosed $game

    $script:ChangesStarted = $true
    New-Item -ItemType Directory -Path $recordDir -Force | Out-Null
    $record = [ordered]@{
        tool              = $ToolName
        toolVersion       = $ToolVersion
        installedAt       = (Get-Date).ToString('s')
        completed         = $false
        gameFolder        = $game
        reshadeVersion    = $m.reshade.version
        reshadeFile       = $m.reshade.installAs
        reshadeSha256     = $m.reshade.dllSha256
        reshadeInstalled  = $true
        gposingwayVersion = $m.gposingway.version
        packItems         = @($m.gposingway.allowedTopLevel)
        packFileCount     = $inside.Files
        packBytes         = $inside.Bytes
        backupFolder      = $origBackup
        backedUp          = @($origNames)
    }
    # If ReShade was already here and matching, it only counts as "ours"
    # (to remove on uninstall) when an earlier run of this tool installed it.
    if ($reshadeDone) { $record.reshadeInstalled = [bool]($prev -and $prev.reshadeInstalled) }
    $recordPath = Join-Path $recordDir 'install-record.json'

    # Two kinds of existing files get moved aside:
    #   - files from before this tool was ever used: kept to restore on uninstall
    #   - files a previous run of this tool installed: kept, but not restored
    $restoreDir  = $backupDir
    if ($origBackup) { $restoreDir = $origBackup }
    $replacedDir = "$backupDir-previous-install"
    $restoreNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in $origNames) { $restoreNames.Add([string]$name) }
    foreach ($name in $toBackUp) {
        $isOurs = ($oursAlready -contains $name) -or (Test-Path -LiteralPath (Join-Path $restoreDir $name))
        $destDir = $restoreDir
        if ($isOurs) { $destDir = $replacedDir } else { $restoreNames.Add($name) }
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Move-Item -LiteralPath (Join-Path $game $name) -Destination (Join-Path $destDir $name)
        Say-Ok "Moved $name to the backup folder."
    }
    if ($restoreNames.Count -gt 0) {
        $record.backupFolder = $restoreDir
        $record.backedUp     = @($restoreNames.ToArray())
    }
    # Written before copying, so Uninstall can undo a half-finished install.
    ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recordPath -Encoding UTF8

    if (-not $reshadeDone) {
        Copy-Item -LiteralPath $reshadeDll -Destination $dxgi -Force
        Say-Ok "Added $($m.reshade.installAs)."
    }
    Say '  Unpacking effects and presets. This takes a minute or two...'
    $unpacked = Invoke-Pack -ZipPath $pack -Destination $game -AllowedTopLevel $m.gposingway.allowedTopLevel -Mode Unpack
    Say-Ok "Unpacked $($unpacked.Files) files."

    # --- Step 6 -----------------------------------------------------------
    Say-Step 6 $steps 'Double-check the result'
    Say '  Comparing your game folder against what should have been installed...'
    $recordObject = Get-Record $game
    $failed = Show-Checks (Get-InstallChecks -Game $game -Record $recordObject -PackZip $pack)
    if ($failed -gt 0) {
        $script:ExitCode = 1
        Say ''
        Say "  $failed check(s) did not pass, so the install is not complete." 'Red'
        Say '  Nothing is harmed: run Install.cmd again to repair it, or'
        Say '  Uninstall.cmd to put everything back the way it was.'
        Say "  The log is at: $LogPath"
        return
    }
    $record.completed = $true
    ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recordPath -Encoding UTF8

    Say ''
    Say '  All done, and every check passed.' 'Green'
    Say ''
    Say '  What to do next:'
    Say '    1. Start the game as usual. A ReShade banner appears at the top'
    Say '       for a moment while effects load. That means it worked.'
    Say '    2. Press Shift+F2 to open the ReShade menu and pick a preset' 'White'
    Say '       from the list at the top.'
    Say '    3. Press Shift+F3 to switch all effects off or on. Effects cost' 'White'
    Say '       performance, so many players switch them off for hard fights.'
    Say ''
    Say '  If no banner appears, run Check.cmd: it tells you whether ReShade'
    Say '  started with the game and what to do if it did not.'
    Say '  Help and troubleshooting:'
    Say '    https://github.com/gposingway/gposingway/blob/main/md/troubleshooting.md'
    Say '  To undo everything, run Uninstall.cmd.'
    Say "  A full log of this run is at: $LogPath"
    Say ''
    if (Ask-YesNo -DefaultNo -Question ("  Delete the downloaded pack to free up {0}? (It is no longer needed)" -f (Format-Size $m.gposingway.size))) {
        Remove-Item -LiteralPath $pack -Force
        Say-Ok 'Deleted.'
    }
}

# ---------------------------------------------------------------------------
#  The check-up (changes nothing)
# ---------------------------------------------------------------------------

function Start-Check {
    Say ''
    Say '  Check my ReShade + GPosingway install' 'White'
    Say '  This only looks. It changes nothing.'
    Say-Ok 'Self-check passed: this PC can run the walkthrough.'
    Say ''
    $game = Select-GameFolder
    Say-Ok "Looking at: $game"
    Say ''
    $record = Get-Record $game
    $logInfo = Get-ReShadeLogInfo $game

    if (-not $record) {
        Say-Note 'This walkthrough has not installed anything here, so I can only describe what I see:'
        $dll = Join-Path $game 'dxgi.dll'
        if (Test-Path -LiteralPath $dll) { Say "    dxgi.dll is present and says it is: '$(Get-ProductName $dll)'" }
        else { Say '    dxgi.dll is not present, so ReShade is not installed in the usual way.' }
        foreach ($name in @('reshade-shaders', 'reshade-presets', 'ReShade.ini')) {
            if (Test-Path -LiteralPath (Join-Path $game $name)) { Say "    $name is present" } else { Say "    $name is not present" }
        }
        if ($logInfo) { Say "    ReShade last started with the game on $($logInfo.When.ToString('yyyy-MM-dd HH:mm')) (version $($logInfo.Version))" }
        Say ''
        Say '  Run Install.cmd if you would like this walkthrough to set it up.'
        return
    }

    if (-not (Get-Prop $record 'completed' $true)) {
        Say-Note 'The last install here did not finish.'
    }
    $failed = Show-Checks (Get-InstallChecks -Game $game -Record $record)

    Say ''
    $installedAt = Get-Prop $record 'installedAt' $null
    if ($installedAt -and $installedAt -isnot [DateTime]) {
        try { $installedAt = [DateTime]::Parse([string]$installedAt, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $installedAt = $null }
    }
    if (-not $logInfo) {
        Say-Note 'ReShade has not started with the game yet. Start the game once, then'
        Say '       run this check again. You should see a ReShade banner at the top'
        Say '       of the screen while the game loads.'
    } elseif ($installedAt -and $logInfo.When -lt $installedAt) {
        Say-Note 'ReShade has not started with the game since this install. Start the'
        Say '       game once, then run this check again.'
    } else {
        Say-Ok "ReShade started with the game on $($logInfo.When.ToString('yyyy-MM-dd HH:mm')) (version $($logInfo.Version))."
        Say '       In game, Shift+F2 opens its menu and Shift+F3 switches effects on and off.'
    }

    Say ''
    if ($failed -gt 0) {
        $script:ExitCode = 1
        Say "  $failed check(s) did not pass. See the advice next to each one above." 'Red'
    } else {
        Say '  Everything this walkthrough installed is in place.' 'Green'
    }
}

# ---------------------------------------------------------------------------
#  The uninstall walkthrough
# ---------------------------------------------------------------------------

function Start-Uninstall {
    Say ''
    Say '  Remove ReShade + GPosingway' 'White'
    if ($DryRun) { Say '  PREVIEW MODE: nothing will be changed.' 'Magenta' }
    Say ''
    $game = Select-GameFolder
    $record = Get-Record $game
    if (-not $record) {
        Stop-Here ("I have no record of installing anything in $game, so I won't remove anything. " +
                   'If you installed ReShade another way, use the uninstall option in its own setup program.')
    }
    Wait-GameClosed $game

    $recordDir = Join-Path $game $RecordFolder
    $dxgi = Join-Path $game $record.reshadeFile
    $removeDll = $false
    if ($record.reshadeInstalled -and (Test-Path -LiteralPath $dxgi)) {
        if (Test-Fingerprint $dxgi $record.reshadeSha256) { $removeDll = $true }
        else { Say-Note "$($record.reshadeFile) has changed since I installed it, so I will leave it alone." }
    }

    $extras = @('ReShade.log', 'ReShadePreset.ini') | Where-Object { Test-Path -LiteralPath (Join-Path $game $_) }
    Say '  This will change the following in:'
    Say "    $game" 'White'
    if ($removeDll) { Say "    remove  $($record.reshadeFile)" }
    foreach ($name in $record.packItems) {
        if (Test-Path -LiteralPath (Join-Path $game $name)) { Say "    remove  $name" }
    }
    foreach ($name in $extras) { Say "    remove  $name  (made by ReShade while running)" }
    $hasBackup = $record.backupFolder -and (Test-Path -LiteralPath $record.backupFolder)
    if ($hasBackup) {
        foreach ($name in $record.backedUp) { Say "    restore $name  (from the backup made at install)" }
    }
    Say ''
    Say-Note 'Presets you saved inside reshade-presets will be removed too.'
    if ($DryRun) { Say-Preview 'Preview finished. Nothing was changed.'; return }
    if (-not (Ask-YesNo '  Go ahead?')) { Stop-Here 'No changes were made.' }
    if (-not (Test-CanWrite $game)) {
        Stop-Here ('Windows is not letting me write to the game folder. Close this window, right-click Uninstall.cmd, ' +
                   'choose "Run as administrator", and start again. I changed nothing.')
    }

    $script:ChangesStarted = $true
    if ($removeDll) { Remove-Item -LiteralPath $dxgi -Force; Say-Ok "Removed $($record.reshadeFile)." }
    foreach ($name in $record.packItems) {
        $path = Join-Path $game $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Say-Ok "Removed $name." }
    }
    foreach ($name in $extras) { Remove-Item -LiteralPath (Join-Path $game $name) -Force }
    if ($hasBackup) {
        foreach ($name in $record.backedUp) {
            $from = Join-Path $record.backupFolder $name
            $to   = Join-Path $game $name
            if ((Test-Path -LiteralPath $from) -and -not (Test-Path -LiteralPath $to)) {
                Move-Item -LiteralPath $from -Destination $to
                Say-Ok "Restored $name."
            }
        }
    }
    Remove-Item -LiteralPath (Join-Path $recordDir 'install-record.json') -Force
    $left = @(Get-ChildItem -LiteralPath $recordDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $recordDir -Recurse -Force }
    else {
        Say-Note "Files from earlier installs (including presets you saved) are kept in:"
        Say "       $recordDir"
        Say "       Delete that folder once you no longer need them."
    }

    Say ''
    Say '  Done. Your game folder is back to how it was.' 'Green'
}

# ---------------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------------

try {
    Write-Log "=== $ToolName $ToolVersion started (DryRun=$DryRun, Uninstall=$Uninstall, Check=$Check) ==="
    Test-Environment
    Enter-SingleInstance
    if ($Check) { Start-Check } elseif ($Uninstall) { Start-Uninstall } else { Start-Install }
} catch {
    $message = [string]$_.Exception.Message
    Write-Host ''
    if ($message.StartsWith($StopPrefix)) {
        Say ('  ' + $message.Substring($StopPrefix.Length)) 'Yellow'
    } else {
        Say '  Something unexpected went wrong, so I stopped.' 'Red'
        Say "  $message" 'Red'
        if ($script:ChangesStarted) {
            Say '  Your game folder may be only partly changed. Run Uninstall.cmd to put'
            Say '  it back the way it was, or run Install.cmd to try again.'
        } else {
            Say '  Nothing in your game folder was changed.'
        }
        Say "  Details are in the log: $LogPath"
        Write-Log ($_ | Out-String)
    }
    $script:ExitCode = 1
} finally {
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        try { $script:Mutex.Dispose() } catch { }
    }
}
Write-Host ''
exit $script:ExitCode
