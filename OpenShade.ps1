#Requires -Version 5.1
<#
.SYNOPSIS
    Installs ReShade and GPosingway for FINAL FANTASY XIV.

.DESCRIPTION
    Downloads ReShade (https://github.com/crosire/reshade) and GPosingway
    (https://github.com/gposingway/gposingway) from their official sources,
    verifies them against the SHA-256 checksums in manifest.json, and installs
    them into the game folder. Existing files are backed up first.

.PARAMETER DryRun
    Shows every step. Downloads and changes nothing.

.PARAMETER Uninstall
    Removes what was installed and restores what was backed up, then offers
    to delete the downloaded files.

.PARAMETER Check
    Read-only. Reports whether an existing install is complete.

.PARAMETER Menu
    Shows the menu. Used by OpenShade.cmd.

.PARAMETER GamePath
    Game folder (the one that contains ffxiv_dx11.exe). Skips detection.

.PARAMETER ManifestPath
    Manifest file to use instead of manifest.json. Used by the tests.

.PARAMETER CacheDir
    Download folder to use instead of the default. Used by the tests.

.PARAMETER AssumeYes
    Answers yes to every prompt. Used by the tests.

.PARAMETER RequestAdmin
    Opens OpenShade.cmd in an administrator window and exits. Used by
    OpenShade.cmd.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Check,
    [switch]$Menu,
    [string]$GamePath,
    [string]$ManifestPath,
    [string]$CacheDir,
    [switch]$AssumeYes,
    [switch]$RequestAdmin
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Settings
# ---------------------------------------------------------------------------

$ToolTitle    = 'OpenShade XIV'
$ToolName     = 'openshade-xiv'             # folder name under %LOCALAPPDATA%
$ToolVersion  = '0.4.2'
$GameExe      = 'ffxiv_dx11.exe'
$RecordFolder = '.openshade-xiv'            # created inside the game folder
$StopPrefix   = 'OPENSHADE-STOP: '

# A pack that contains any of these file types is refused.
$BlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.bat', '.cmd', '.ps1', '.psm1',
    '.vbs', '.js', '.jse', '.wsf', '.hta', '.lnk', '.reg', '.sys', '.jar',
    '.addon', '.addon32', '.addon64'
)

# Other file names ReShade or GShade can be installed as.
$OtherInjectorNames = @('d3d11.dll', 'd3d9.dll', 'dinput8.dll', 'opengl32.dll')

$MaxPathLength = 259   # MAX_PATH minus the terminator

$LocalBase = $env:LOCALAPPDATA
if (-not $LocalBase) { $LocalBase = $env:TEMP }
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot 'manifest.json' }
$AppData = Join-Path $LocalBase $ToolName
$OwnCache = -not $CacheDir                  # downloads go to this tool's own folder
if ($OwnCache) { $CacheDir = Join-Path $AppData 'downloads' }
$LogPath = Join-Path $AppData 'log.txt'

$script:ExitCode       = 0
$script:ChangesStarted = $false   # set once the game folder is modified
$script:Mutex          = $null

# ---------------------------------------------------------------------------
#  Output and prompts
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

# False with -AssumeYes or when input is redirected.
function Test-Interactive {
    if ($AssumeYes) { return $false }
    try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

# After five unusable answers: returns $false with -DefaultNo, otherwise stops.
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
    Stop-Here 'No valid answer received. Stopped.'
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

# Uses .NET directly. Get-FileHash fails to load when Windows PowerShell is
# started from a PowerShell 7 session.
function Get-Sha256 {
    param([string]$Path)
    $sha = $null
    try { $sha = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider }
    catch { $sha = [System.Security.Cryptography.SHA256]::Create() }
    $stream = [System.IO.File]::OpenRead($Path)
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# Property value, or $Default when absent (older install records).
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

# ---------------------------------------------------------------------------
#  Environment checks
# ---------------------------------------------------------------------------

# Self-tests for hashing, zip and TLS. Stops before anything is changed.
function Test-Environment {
    # Checked first: these work in constrained language mode.
    if ($env:OS -ne 'Windows_NT') { Stop-Here 'This tool requires Windows.' }
    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    if ($mode -ne 'FullLanguage') {
        Stop-Here ("PowerShell on this PC is restricted (language mode: $mode), which is common on managed work or " +
                   'school computers. This tool cannot run here. No changes were made.')
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Stop-Here 'This tool requires 64-bit Windows. No changes were made.'
    }

    $failed = New-Object System.Collections.Generic.List[string]

    # Working folder is writable; hash of a known value
    $probe = $null
    try {
        if (-not (Test-Path -LiteralPath $AppData)) { New-Item -ItemType Directory -Path $AppData -Force | Out-Null }
        $probe = Join-Path $AppData ('selftest-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllBytes($probe, [System.Text.Encoding]::ASCII.GetBytes('openshade-xiv self-test'))
        $hash = Get-Sha256 $probe
        if ($hash -ine 'cd7ebc45286f4e30e4dac9139dcd109f6e2749dfdb31afd22bdf340e90a8b23b') { throw "unexpected checksum $hash" }
    } catch { $failed.Add("file checksums ($($_.Exception.Message))") }
    finally { if ($probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } }

    # Zip round trip
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

    # TLS 1.2 and HttpClient
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
        Stop-Here ('System check failed: ' + ($failed -join '; ') + ". No changes were made. Log: $LogPath")
    }
}

function Enter-SingleInstance {
    try {
        $created = $false
        $script:Mutex = [System.Threading.Mutex]::new($true, "Local\$ToolName", [ref]$created)
        if (-not $created) {
            $script:Mutex.Dispose(); $script:Mutex = $null
            Stop-Here 'Another instance is already running. Close it first.'
        }
    } catch {
        if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw }
    }
}

# ---------------------------------------------------------------------------
#  Administrator permission
# ---------------------------------------------------------------------------

# The game is usually installed under Program Files, where only an
# administrator can add files. OpenShade.cmd therefore asks Windows for
# administrator permission once, when it starts.

# True if this window has administrator permission.
function Test-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal $identity).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Opens OpenShade.cmd in an administrator window. Windows shows its
# permission prompt first. Returns the exit code OpenShade.cmd reads:
# 0 = the window was opened, 2 = this window already has permission,
# 1 = permission was not given.
function Request-Admin {
    try {
        if (Test-Elevated) { return 2 }
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $launcher = Join-Path $PSScriptRoot 'OpenShade.cmd'
        Start-Process -FilePath $cmd -ArgumentList ('/c ""{0}" elevated"' -f $launcher) -Verb RunAs -ErrorAction Stop
        return 0
    } catch { return 1 }
}

# What to tell the player when the game folder cannot be written to.
function Get-CannotWriteText {
    if (Test-Elevated) {
        return ('Cannot write to the game folder, even with administrator permission. Security software may be ' +
                'protecting it; allow this tool or the game folder there, then try again. No changes were made.')
    }
    return ('Cannot write to the game folder. This is common when the game is in "Program Files". Run OpenShade.cmd ' +
            'again and choose Yes when Windows asks for permission. No changes were made.')
}

# ---------------------------------------------------------------------------
#  Game detection
# ---------------------------------------------------------------------------

# Returns the folder that contains ffxiv_dx11.exe, or $null. Accepts that
# folder, its parent, the sibling "boot" folder, or an .exe path in any of them.
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
    if ($Source)       { $bits.Add("source: $Source") }
    if ($bits.Count -eq 0) { return $Folder }
    return ('{0}   ({1})' -f $Folder, ($bits -join ', '))
}

# Read-only lookups of existing records. No drive scan.
function Find-GameFolders {
    $places = New-Object System.Collections.Generic.List[object]
    function Add-Place { param($List, [string]$Path, [string]$Source)
        if ($Path) { $List.Add([pscustomobject]@{ Path = $Path; Source = $Source }) }
    }

    # Running process
    try {
        foreach ($proc in @(Get-Process -Name 'ffxiv_dx11' -ErrorAction SilentlyContinue)) {
            $procPath = $null
            try { $procPath = $proc.Path } catch { }
            Add-Place $places $procPath 'running game process'
        }
    } catch { }

    # XIVLauncher config
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

    # Uninstall registry entries
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
                    Add-Place $places ([string](Get-Prop $item 'InstallLocation' '')) 'installed programs list'
                }
            }
        } catch { }
    }

    # Steam libraries (39210: full game, 312060: free trial)
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

    # Desktop and Start menu shortcuts
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
                # CreateShortcut on an existing .lnk only reads it.
                Add-Place $places ([string]$shell.CreateShortcut($link.FullName).TargetPath) 'shortcut'
            }
        }
    } catch { }

    # MuiCache and Compatibility Assistant entries for FFXIV executables
    $historyKeys = @(
        'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache',
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store'
    )
    foreach ($key in $historyKeys) {
        try {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            foreach ($valueName in (Get-Item -LiteralPath $key).GetValueNames()) {
                $m = [regex]::Match($valueName, '^(?<p>[A-Za-z]:\\.*?\\ffxiv(_dx11|boot|boot64|launcher|launcher64)?\.exe)', 'IgnoreCase')
                if ($m.Success) { Add-Place $places $m.Groups['p'].Value 'recently run programs' }
            }
        } catch { }
    }

    # Default install folders on fixed drives
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName
            foreach ($sub in @('Program Files (x86)\SquareEnix', 'Program Files\SquareEnix', 'SquareEnix', 'Games\SquareEnix', 'Games')) {
                Add-Place $places (Join-Path $root "$sub\FINAL FANTASY XIV - A Realm Reborn") 'default install folder'
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

# File dialog for ffxiv_dx11.exe. Returns $null if cancelled or unavailable.
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
        if (-not $resolved) { Stop-Here "$GameExe not found in: $GamePath" }
        Say-Ok "Game folder: $resolved"
        return $resolved
    }

    $found = @(Find-GameFolders)

    if ($found.Count -eq 1) {
        Say-Ok ('Found: ' + (Format-GameLine $found[0].Path $found[0].Source))
        if (Ask-YesNo '  Use this folder?') { return $found[0].Path }
    } elseif ($found.Count -gt 1) {
        Say '  Multiple installs found:'
        for ($i = 0; $i -lt $found.Count; $i++) {
            Say ("    {0}. {1}" -f ($i + 1), (Format-GameLine $found[$i].Path $found[$i].Source)) 'White'
        }
        Say '  The most recently patched install is usually the active one.'
        if ($AssumeYes) { return $found[0].Path }
        for ($try = 1; $try -le 5; $try++) {
            $pick = Read-Host "  Enter a number (or press Enter to choose another folder)"
            if (-not $pick) { break }
            $n = 0
            if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) { return $found[$n - 1].Path }
        }
    } else {
        Say-Note 'Game not found automatically.'
    }

    if ($AssumeYes) { Stop-Here 'Game folder not found. Use -GamePath to specify it.' }
    $canBrowse = Test-Interactive
    Say ''
    Say '  The game folder usually ends in:'
    Say '    ...\FINAL FANTASY XIV - A Realm Reborn\game' 'White'
    if ($canBrowse) {
        Say "  Press Enter to browse for $GameExe, or paste the folder path."
    } else {
        Say '  Paste the folder path.'
    }
    for ($try = 1; $try -le 8; $try++) {
        $typed = Read-Host '  Game folder (Q to quit)'
        if ($typed -match '^\s*q\s*$') { Stop-Here 'No changes were made.' }
        if (-not $typed -and $canBrowse) { $typed = Show-GamePicker }
        $resolved = Resolve-GameFolder $typed
        if ($resolved) { Say-Ok "Game folder: $resolved"; return $resolved }
        Say-Note "$GameExe not found there."
    }
    Stop-Here 'Game folder not found. No changes were made.'
}

function Confirm-GameFolder {
    param([string]$Game)
    $info = Get-GameInfo $Game
    if (-not $info.LooksComplete) {
        Say-Note "This folder contains $GameExe but not the rest of the game files."
        if (-not (Ask-YesNo '  Use it anyway?')) { Stop-Here 'No changes were made.' }
    }
}

# ---------------------------------------------------------------------------
#  Downloads
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
            Stop-Here ("${Label}: the server returned an error ($([int]$response.StatusCode)). " +
                       'The file may have moved, and this tool may need an update. No changes were made.')
        }
        $total = $response.Content.Headers.ContentLength
        if ($ExpectedSize -and $total -and $total -ne $ExpectedSize) {
            Stop-Here ("${Label}: the file on the server is a different size than expected " +
                       "($total bytes, expected $ExpectedSize). It was not downloaded. " +
                       'Check for an updated version of this tool. No changes were made.')
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

# Returns the path of a download that matches the manifest checksum.
# Reuses a cached copy if it still matches.
function Get-CheckedDownload {
    param($Asset)
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $target = Join-Path $CacheDir $Asset.fileName

    if (Test-Path -LiteralPath $target) {
        if (Test-Fingerprint $target $Asset.sha256) {
            Say-Ok 'Already downloaded. Checksum verified.'
            return $target
        }
        Say-Note 'Existing download is incomplete or different. Downloading again.'
        Remove-Item -LiteralPath $target -Force
    }

    try {
        $free = (Get-Item -LiteralPath $CacheDir).PSDrive.Free
        if ($free -and $free -lt ([long]$Asset.size + 50MB)) {
            Stop-Here ("Not enough free space to download $($Asset.name): $(Format-Size $Asset.size) needed, " +
                       "$(Format-Size $free) free. No changes were made.")
        }
    } catch { if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw } }

    $siteName = ([System.Uri]$Asset.url).Host
    Say "  Downloading ($(Format-Size $Asset.size)): $($Asset.url)"
    for ($attempt = 1; ; $attempt++) {
        try {
            Save-Download -Url $Asset.url -Destination $target -Label $Asset.name -ExpectedSize $Asset.size
            break
        } catch {
            if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw }
            Write-Log ("Download attempt $attempt failed: " + ($_ | Out-String))
            Remove-Item -LiteralPath "$target.part" -Force -ErrorAction SilentlyContinue
            Say-Note "Download from $siteName failed."
            if ($attempt -ge 3 -or -not (Ask-YesNo -DefaultNo '  Retry?')) {
                Stop-Here ("Could not download $($Asset.name) from $siteName. Check the internet connection and any VPN, " +
                           'firewall or antivirus, then run this again. No changes were made.')
            }
        }
    }

    if (-not (Test-Fingerprint $target $Asset.sha256)) {
        Remove-Item -LiteralPath $target -Force
        Stop-Here ("$($Asset.name): the downloaded file does not match the checksum in manifest.json. " +
                   'It was deleted and no changes were made. The download may be incomplete, or the file on the ' +
                   'server may have changed. Try again later, or check for an updated version of this tool.')
    }
    Say-Ok 'Checksum verified.'
    return $target
}

# The ReShade setup executable has a zip archive appended at a 512-byte
# boundary. Extracts one entry from it without running the executable.
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

#   -Mode Inspect : validate entries, write nothing
#   -Mode Unpack  : validate entries, then extract
#   -Mode Verify  : compare the game folder against the pack
# Every entry is validated before anything is written: it must resolve inside
# the game folder, sit under an allowed top-level item, not be a blocked file
# type, and fit within the path length limit.
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
                Stop-Here "The pack contains an unexpected item ('$top'). Nothing was unpacked."
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Here "The pack contains a path outside the game folder ('$relative'). Nothing was unpacked."
            }
            $isFolder = $relative.EndsWith('\')
            if (-not $isFolder) {
                $ext = [System.IO.Path]::GetExtension($relative).ToLowerInvariant()
                if ($BlockedExtensions -contains $ext) {
                    Stop-Here "The pack contains a program or script ('$relative'). Nothing was unpacked."
                }
                $bytes += $entry.Length
            }
            if ($target.Length -gt $MaxPathLength) {
                Stop-Here ("The game folder path is too long for some pack files (Windows allows about 260 characters; " +
                           "'$relative' needs $($target.Length)). Move the game to a shorter path. Nothing was unpacked.")
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
                Write-Progress -Activity 'Unpacking shaders and presets' -Status "$n of $($files.Count) files" -PercentComplete ([int](100 * $n / $files.Count))
            }
        }
        Write-Progress -Activity 'Unpacking shaders and presets' -Completed
        return $result
    } finally {
        $zip.Dispose()
    }
}

# ---------------------------------------------------------------------------
#  Game folder state
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

# True if this account may change the file. Opens it for writing and closes
# it again; the file is not modified.
function Test-CanModify {
    param([string]$File)
    try {
        $stream = [System.IO.File]::Open($File, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stream.Dispose()
        return $true
    } catch { return $false }
}

# True if the game is running from this folder. A process whose path cannot
# be read counts as a match.
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
        Say-Note 'The game is running. Close it before continuing.'
        if ($DryRun) { Say '       (Preview mode: continuing.)'; return }
        $tries++
        if ($AssumeYes -or $tries -gt 10) { Stop-Here 'The game is running. Close it and run this again.' }
        Wait-Enter '  Press Enter when the game is closed'
    }
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Stop-Here ('manifest.json was not found next to this script. If this was opened from inside a zip file, ' +
                   'extract the whole folder first (right-click the zip, "Extract All").')
    }
    try { $m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json }
    catch { Stop-Here 'manifest.json is damaged and cannot be read. Download a fresh copy of this tool.' }
    foreach ($hash in @((Get-Prop (Get-Prop $m 'reshade') 'sha256' ''), (Get-Prop (Get-Prop $m 'reshade') 'dllSha256' ''),
                        (Get-Prop (Get-Prop $m 'gposingway') 'sha256' ''))) {
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') {
            Stop-Here 'manifest.json is missing a checksum. Download a fresh copy of this tool.'
        }
    }
    foreach ($url in @($m.reshade.url, $m.gposingway.url)) {
        if ($url -notmatch '^https?://') { Stop-Here 'manifest.json contains an invalid download address. Download a fresh copy of this tool.' }
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

# Last start time and version from ReShade.log.
function Get-ReShadeLogInfo {
    param([string]$Game)
    try {
        $log = Join-Path $Game 'ReShade.log'
        if (-not (Test-Path -LiteralPath $log)) { return $null }
        # The install creates an empty log; ReShade fills it when the game starts.
        if ((Get-Item -LiteralPath $log).Length -eq 0) { return $null }
        $version = ''
        foreach ($line in @(Get-Content -LiteralPath $log -TotalCount 40 -ErrorAction SilentlyContinue)) {
            if ($line -match "ReShade version '([^']+)'") { $version = $Matches[1]; break }
        }
        return [pscustomobject]@{ When = (Get-Item -LiteralPath $log).LastWriteTime; Version = $version }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
#  Save access for ReShade
# ---------------------------------------------------------------------------

# ReShade runs inside the game, which does not run as administrator. When the
# game is in a protected folder such as Program Files, ReShade cannot save its
# settings, presets or screenshots unless the player's Windows account is
# allowed to change those files. ReShade's own setup program grants the same
# access; this tool does not run that program, so it grants it here.

# The account that plays the game: the owner of the desktop in this session.
# It differs from the current account when this tool was started with another
# account's administrator password.
function Get-PlayerSid {
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $shell = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $session" -ErrorAction Stop |
            Select-Object -First 1
        if ($shell) {
            $sid = [string](Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if ($sid -match '^S-1-\d+(-\d+)+$') { return $sid }
        }
    } catch { }
    return $current
}

function Get-AccountName {
    param([string]$Sid)
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value
    } catch { return $Sid }
}

# True for a single folder name with no path in it.
function Test-PlainName {
    param([string]$Name)
    return ($Name -match '^[^\\/:*?"<>|]+$' -and $Name -notmatch '^\.+$')
}

# The screenshot folder named in ReShade.ini, when it is a plain folder inside
# the game folder (SavePath=.\name\). Otherwise ''.
function Get-ScreenshotFolder {
    param([string]$Game)
    try {
        $ini = Join-Path $Game 'ReShade.ini'
        if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { return '' }
        $inSection = $false
        foreach ($line in @(Get-Content -LiteralPath $ini)) {
            if ($line -match '^\s*\[(.+)\]\s*$') { $inSection = ($Matches[1] -eq 'SCREENSHOT'); continue }
            if ($inSection -and $line -match '^SavePath=\.\\([^\\]+)\\?\s*$') {
                $name = $Matches[1].Trim()
                if (Test-PlainName $name) { return $name }
                return ''
            }
        }
    } catch { }
    return ''
}

# The permission list of a file or folder. Windows PowerShell and PowerShell 7
# reach the same Windows function by different names.
function Get-AccessList {
    param($Item)
    $part = [System.Security.AccessControl.AccessControlSections]::Access
    if ($PSVersionTable.PSEdition -eq 'Core') { return [System.IO.FileSystemAclExtensions]::GetAccessControl($Item, $part) }
    return $Item.GetAccessControl($part)
}

# Adds "this account may change this file" to the item's permissions. On a
# folder it also applies to everything inside. Nothing else is changed.
function Add-ModifyRule {
    param([string]$Path, [string]$Sid)
    $item = Get-Item -LiteralPath $Path -Force
    $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    if ($item.PSIsContainer) {
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier $Sid),
        [System.Security.AccessControl.FileSystemRights]::Modify,
        $inherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl = Get-AccessList $item
    $acl.AddAccessRule($rule)
    if ($PSVersionTable.PSEdition -eq 'Core') { [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl) }
    else { $item.SetAccessControl($acl) }
}

# True if the account may change the file when it is not running as
# administrator. Reads the file's permissions for the account itself and for
# the groups every signed-in user is in. If they cannot be read (a drive
# without permissions, for example), falls back to trying to open the file.
function Test-AccountCanModify {
    param([string]$File, [string]$Sid)
    try {
        # Everyone, Authenticated Users, Users, Interactive.
        $who = @($Sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4')
        $write = [int][System.Security.AccessControl.FileSystemRights]::WriteData
        $allowed = 0
        $denied = 0
        $acl = Get-AccessList (Get-Item -LiteralPath $File -Force)
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($who -notcontains $rule.IdentityReference.Value) { continue }
            $rights = [int]$rule.FileSystemRights
            # "Generic all" and "generic write" include writing.
            if (($rights -band 0x10000000) -or ($rights -band 0x40000000)) { $rights = $rights -bor $write }
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) { $denied = $denied -bor $rights }
            else { $allowed = $allowed -bor $rights }
        }
        return ((($allowed -band (-bnot $denied)) -band $write) -ne 0)
    } catch { return (Test-CanModify $File) }
}

# Allows the account to change each named item in the game folder. Returns
# the names that could not be changed.
function Grant-SaveAccess {
    param([string]$Game, [string]$Sid, [string[]]$Names)
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        try { Add-ModifyRule -Path (Join-Path $Game $name) -Sid $Sid }
        catch { $failed.Add($name); Write-Log "ACCESS $name failed: $($_.Exception.Message)" }
    }
    return $failed.ToArray()
}

# ---------------------------------------------------------------------------
#  Install checks
# ---------------------------------------------------------------------------

# Returns checks with a name, result and advice. With -PackZip, every file
# is compared against the pack.
function Get-InstallChecks {
    param([string]$Game, $Record, [string]$PackZip)
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check { param($List, [string]$Name, [bool]$Ok, [string]$Advice = '')
        $List.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Advice = $Advice })
    }
    $rerun = 'Run OpenShade.cmd and choose Install to repair.'
    $antivirus = 'The file may have been removed or blocked by security software. Run the install again; if it is ' +
                 'removed again, add the game folder as an exception.'

    Add-Check $checks "Game executable present ($GameExe)" (Test-Path -LiteralPath (Join-Path $Game $GameExe) -PathType Leaf) `
        'The game folder has moved or been removed. Run the install again and select the new location.'

    $reshadeFile = [string](Get-Prop $Record 'reshadeFile' 'dxgi.dll')
    $dll = Join-Path $Game $reshadeFile
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        Add-Check $checks "ReShade present ($reshadeFile)" $false $antivirus
    } else {
        $version = [string](Get-Prop $Record 'reshadeVersion' '')
        Add-Check $checks "ReShade $version present and unmodified ($reshadeFile)" (Test-Fingerprint $dll ([string](Get-Prop $Record 'reshadeSha256' ''))) `
            ('The file differs from the installed version. Another tool may have replaced it. ' + $rerun)
    }

    $packItems = @(Get-Prop $Record 'packItems' @())
    $missing = @($packItems | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Game $_)) })
    Add-Check $checks 'Shader and preset folders present' ($missing.Count -eq 0) ("Missing: $($missing -join ', '). " + $rerun)

    if ($PackZip) {
        $verify = Invoke-Pack -ZipPath $PackZip -Destination $Game -AllowedTopLevel $packItems -Mode Verify
        foreach ($p in @($verify.Problems | Select-Object -First 20)) { Write-Log "VERIFY $p" }
        Add-Check $checks "All pack files present and correct size ($($verify.Files) files)" ($verify.Problems.Count -eq 0) `
            ("$($verify.Problems.Count) file(s) missing or wrong size (see log). " + $rerun)
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
            Add-Check $checks "Pack files present ($present found, $expected installed)" ($present -ge $expected) `
                ("$($expected - $present) file(s) missing since install. " + $rerun)
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
        Add-Check $checks 'ReShade.ini points to the installed shaders' $pointsAtPack `
            ('ReShade.ini is missing or points elsewhere; presets may show no effects. ' + $rerun)
    }
    if (Test-Path -LiteralPath $ini -PathType Leaf) {
        # An administrator window can always write, so there the permissions
        # of the account that plays are read instead.
        if (Test-Elevated) { $canSave = Test-AccountCanModify $ini (Get-PlayerSid) } else { $canSave = Test-CanModify $ini }
        Add-Check $checks 'ReShade can save its settings' $canSave `
            ('The Windows account that plays the game is not allowed to change ReShade.ini, so ReShade cannot save ' +
             'settings or presets. Run OpenShade.cmd, choose Yes when Windows asks for permission, then choose Install to repair.')
    }
    return $checks.ToArray()
}

# Prints the checks. Returns the number that failed.
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
#  Install
# ---------------------------------------------------------------------------

function Start-Install {
    $m = Read-Manifest
    $steps = 6

    Say ''
    if (-not $Menu) {
        Say "  $ToolTitle $ToolVersion" 'White'
        Say '  ReShade + GPosingway setup for FINAL FANTASY XIV'
        Say ''
    }
    if ($DryRun) { Say '  PREVIEW MODE: nothing is downloaded or changed.' 'Magenta'; Say '' }
    Say '  Installs:'
    Say ('    {0}{1}' -f "ReShade $($m.reshade.version) (add-on edition)".PadRight(34), $m.reshade.homepage) 'White'
    Say ('    {0}{1}' -f "GPosingway $($m.gposingway.version)".PadRight(34), $m.gposingway.homepage) 'White'
    Say ''
    Say '  Downloads are verified against the SHA-256 checksums in manifest.json.'
    Say '  Existing files are backed up before being replaced.'
    Say ''
    Say '  Unofficial community tool. Not affiliated with Square Enix.'
    Say ''
    if (-not (Ask-YesNo '  Continue?')) { Stop-Here 'No changes were made.' }

    Say-Step 1 $steps 'Locate game'
    $game = Select-GameFolder
    Confirm-GameFolder $game
    Wait-GameClosed $game

    Say-Step 2 $steps 'Existing files'
    $dxgi        = Join-Path $game $m.reshade.installAs
    $recordDir   = Join-Path $game $RecordFolder
    $stamp       = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $backupDir   = Join-Path (Join-Path $recordDir 'backup') $stamp
    $toBackUp    = New-Object System.Collections.Generic.List[string]
    $reshadeDone = $false

    # On a repeat install, keep the first backup so Uninstall restores the
    # original state.
    $prev         = Get-Record $game
    $origBackup   = $null      # backup folder from the first install
    $origNames    = @()        # names in that backup
    $oursAlready  = @()        # items an earlier run installed
    if ($prev) {
        if ($prev.backupFolder) { $origBackup = [string]$prev.backupFolder }
        $origNames   = @($prev.backedUp)
        $oursAlready = @($prev.packItems)
        if ($prev.reshadeInstalled) { $oursAlready += [string]$prev.reshadeFile }
        if (Get-Prop $prev 'completed' $true) { Say '  A previous install by this tool was found. It will be refreshed.' }
        else { Say-Note 'A previous run did not finish. Starting over.' }
    }

    $gshadeFiles = @(@($m.reshade.installAs) + $OtherInjectorNames | Where-Object {
        (Test-Path -LiteralPath (Join-Path $game $_)) -and ((Get-ProductName (Join-Path $game $_)) -like '*GShade*') })
    if ((Test-Path -LiteralPath (Join-Path $game 'GShade.ini')) -or $gshadeFiles.Count -gt 0) {
        Stop-Here ('GShade is installed in this game folder. Uninstall it first ' +
                   '(Windows Settings > Apps > GShade), then run this again. No changes were made.')
    }

    if (Test-Path -LiteralPath $dxgi) {
        if (Test-Fingerprint $dxgi $m.reshade.dllSha256) {
            Say-Ok "ReShade $($m.reshade.version) is already installed."
            $reshadeDone = $true
        } else {
            $product = Get-ProductName $dxgi
            if ($product -like '*ReShade*') {
                Say "  A different ReShade version is installed. It will be backed up and replaced with $($m.reshade.version)."
            } else {
                Say-Note "$($m.reshade.installAs) exists but is not ReShade (product: '$product')."
                if (-not (Ask-YesNo '  Move it to the backup folder and continue?')) { Stop-Here 'No changes were made.' }
            }
            $toBackUp.Add($m.reshade.installAs)
        }
    } else {
        Say '  ReShade is not installed.'
    }

    # A second copy of ReShade under another file name would load twice.
    foreach ($name in $OtherInjectorNames) {
        $other = Join-Path $game $name
        if ((Test-Path -LiteralPath $other) -and ((Get-ProductName $other) -like '*ReShade*')) {
            Say-Note "ReShade is also installed as $name. It will be moved to the backup folder to avoid a conflict."
            $toBackUp.Add($name)
        }
    }

    foreach ($name in $m.gposingway.allowedTopLevel) {
        if (Test-Path -LiteralPath (Join-Path $game $name)) { $toBackUp.Add($name) }
    }
    if ($toBackUp.Count -gt 0) {
        Say '  Existing files to be backed up:'
        foreach ($name in $toBackUp) { Say "    $name" 'White' }
        Say "  Backup location: $(Join-Path $recordDir 'backup')"
    } else {
        Say-Ok 'Nothing to back up.'
    }

    if (-not $DryRun) {
        if (-not (Test-CanWrite $game)) { Stop-Here (Get-CannotWriteText) }
        try {
            $free = (Get-Item -LiteralPath $game).PSDrive.Free
            $need = [long]$m.gposingway.size * 2 + 100MB
            if ($free -and $free -lt $need) {
                Say-Note ("Low disk space: {0} free, about {1} needed." -f (Format-Size $free), (Format-Size $need))
                if (-not (Ask-YesNo '  Continue anyway?')) { Stop-Here 'No changes were made.' }
            }
        } catch { if (([string]$_.Exception.Message).StartsWith($StopPrefix)) { throw } }
    }

    Say-Step 3 $steps 'ReShade'
    $reshadeDll = $null
    if ($reshadeDone) {
        Say-Ok 'Already installed. Skipped.'
    } elseif ($DryRun) {
        Say-Preview "Would download $($m.reshade.fileName) ($(Format-Size $m.reshade.size)) from $($m.reshade.url)"
        Say-Preview "Would verify it and extract $($m.reshade.dllEntry)."
    } else {
        $setup = Get-CheckedDownload $m.reshade
        $reshadeDll = Join-Path $CacheDir ("ReShade64-$($m.reshade.version).dll")
        if (-not (Export-ReShadeDll -SetupPath $setup -EntryName $m.reshade.dllEntry -OutPath $reshadeDll)) {
            Stop-Here "$($m.reshade.dllEntry) was not found in the ReShade setup file. No changes were made."
        }
        if (-not (Test-Fingerprint $reshadeDll $m.reshade.dllSha256)) {
            Remove-Item -LiteralPath $reshadeDll -Force
            Stop-Here 'The extracted ReShade file does not match the checksum in manifest.json. No changes were made.'
        }
        Say-Ok "Extracted $($m.reshade.dllEntry) and verified it. The setup program was not run."
    }

    Say-Step 4 $steps 'GPosingway'
    $pack = $null
    $inside = $null
    if ($DryRun) {
        Say-Preview "Would download $($m.gposingway.fileName) ($(Format-Size $m.gposingway.size)) from $($m.gposingway.url)"
        Say-Preview 'Would verify it and inspect every file before unpacking.'
    } else {
        $pack = Get-CheckedDownload $m.gposingway
        $inside = Invoke-Pack -ZipPath $pack -Destination $game -AllowedTopLevel $m.gposingway.allowedTopLevel -Mode Inspect
        Say-Ok "$($inside.Files) files. No programs or scripts."
    }

    Say-Step 5 $steps 'Install'
    Say '  Changes to be made in:'
    Say "    $game" 'White'
    foreach ($name in $toBackUp) { Say "    move    $name  ->  backup" }
    if (-not $reshadeDone) { Say "    add     $($m.reshade.installAs)  (ReShade)" }
    foreach ($name in $m.gposingway.allowedTopLevel) { Say "    add     $name" }
    Say '    allow   your Windows account to change the ReShade settings, presets and screenshot folder'
    Say ''
    if ($DryRun) {
        Say-Preview 'Preview complete. Nothing was downloaded or changed.'
        Say '  To install, run OpenShade.cmd and choose Install.'
        return
    }
    if (-not (Ask-YesNo '  Proceed?')) { Stop-Here 'No changes were made.' }
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
        saveAccessFor     = $null      # account allowed to change the ReShade settings
        screenshotFolder  = $null      # screenshot folder created by this tool
    }
    # A matching ReShade that was already present is removed on uninstall
    # only if an earlier run installed it.
    if ($reshadeDone) { $record.reshadeInstalled = [bool]($prev -and $prev.reshadeInstalled) }
    $recordPath = Join-Path $recordDir 'install-record.json'

    # Files that predate this tool go to the restore folder. Files from an
    # earlier run go to a separate folder and are not restored.
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
        Say-Ok "Moved $name to backup."
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
    $unpacked = Invoke-Pack -ZipPath $pack -Destination $game -AllowedTopLevel $m.gposingway.allowedTopLevel -Mode Unpack
    Say-Ok "Unpacked $($unpacked.Files) files."

    # Let ReShade save. See "Save access for ReShade" above.
    $saveNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('ReShade.log', 'ReShadePreset.ini')) {
        $path = Join-Path $game $name
        if (-not (Test-Path -LiteralPath $path)) { [System.IO.File]::WriteAllBytes($path, (New-Object byte[] 0)) }
    }
    foreach ($name in @('ReShade.ini', 'ReShade.log', 'ReShadePreset.ini', 'reshade-presets')) {
        if (Test-Path -LiteralPath (Join-Path $game $name)) { $saveNames.Add($name) }
    }
    # The screenshot folder is created here because ReShade could not create it
    # in a protected game folder. One that already exists is left alone unless
    # an earlier run of this tool created it.
    $shots = Get-ScreenshotFolder $game
    if ($shots) {
        $shotsPath = Join-Path $game $shots
        $oursBefore = ($prev -and ([string](Get-Prop $prev 'screenshotFolder' '') -eq $shots))
        if (-not (Test-Path -LiteralPath $shotsPath)) {
            New-Item -ItemType Directory -Path $shotsPath | Out-Null
            $oursBefore = $true
        }
        if ($oursBefore -and (Test-Path -LiteralPath $shotsPath -PathType Container)) {
            $record.screenshotFolder = $shots
            $saveNames.Add($shots)
        }
    }
    $playerSid = Get-PlayerSid
    $noAccess = @(Grant-SaveAccess -Game $game -Sid $playerSid -Names $saveNames.ToArray())
    $record.saveAccessFor = $playerSid
    ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recordPath -Encoding UTF8
    if ($noAccess.Count -eq 0) {
        $what = 'the ReShade settings and presets'
        if ($record.screenshotFolder) { $what = 'the ReShade settings, presets and screenshot folder' }
        Say-Ok "Allowed $(Get-AccountName $playerSid) to change $what."
    } else {
        Say-Note "Could not set permissions on: $($noAccess -join ', ')."
        Say '       If ReShade reports that it cannot save, run OpenShade.cmd again, choose Yes when Windows asks'
        Say '       for permission, and choose Install.'
    }

    Say-Step 6 $steps 'Verify'
    $recordObject = Get-Record $game
    $failed = Show-Checks (Get-InstallChecks -Game $game -Record $recordObject -PackZip $pack)
    if ($failed -gt 0) {
        $script:ExitCode = 1
        Say ''
        Say "  $failed check(s) failed. The install is incomplete." 'Red'
        Say '  Run OpenShade.cmd and choose Install to repair, or Uninstall to restore the previous state.'
        Say "  Log: $LogPath"
        return
    }
    $record.completed = $true
    ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recordPath -Encoding UTF8

    Say ''
    Say '  Installation complete. All checks passed.' 'Green'
    Say ''
    Say '  In game: Shift+F2 opens the ReShade menu (pick a preset at the top). Shift+F3 toggles effects.'
    Say '  Troubleshooting: https://github.com/gposingway/gposingway/blob/main/md/troubleshooting.md'
    Say "  Log: $LogPath"
    Say ''
    if (Ask-YesNo -DefaultNo -Question ("  Delete the downloaded pack ({0})?" -f (Format-Size $m.gposingway.size))) {
        Remove-Item -LiteralPath $pack -Force
        Say-Ok 'Deleted.'
    }
}

# ---------------------------------------------------------------------------
#  Check (read-only)
# ---------------------------------------------------------------------------

function Start-Check {
    Say ''
    Say "  $ToolTitle $ToolVersion - install check (read-only)" 'White'
    Say ''
    $game = Select-GameFolder
    Say ''
    $record = Get-Record $game
    $logInfo = Get-ReShadeLogInfo $game

    if (-not $record) {
        Say-Note 'No install by this tool was found here. Current state:'
        $dll = Join-Path $game 'dxgi.dll'
        if (Test-Path -LiteralPath $dll) { Say "    dxgi.dll: present (product: '$(Get-ProductName $dll)')" }
        else { Say '    dxgi.dll: not present' }
        foreach ($name in @('reshade-shaders', 'reshade-presets', 'ReShade.ini')) {
            if (Test-Path -LiteralPath (Join-Path $game $name)) { Say "    ${name}: present" } else { Say "    ${name}: not present" }
        }
        if ($logInfo) { Say "    ReShade last started with the game: $($logInfo.When.ToString('yyyy-MM-dd HH:mm')) (version $($logInfo.Version))" }
        Say ''
        Say '  To install, run OpenShade.cmd and choose Install.'
        return
    }

    if (-not (Get-Prop $record 'completed' $true)) {
        Say-Note 'The last install did not finish.'
    }
    $failed = Show-Checks (Get-InstallChecks -Game $game -Record $record)

    Say ''
    $installedAt = Get-Prop $record 'installedAt' $null
    if ($installedAt -and $installedAt -isnot [DateTime]) {
        try { $installedAt = [DateTime]::Parse([string]$installedAt, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $installedAt = $null }
    }
    if (-not $logInfo) {
        Say-Note 'ReShade has not started with the game yet. Start the game once, then run this check again.'
    } elseif ($installedAt -and $logInfo.When -lt $installedAt) {
        Say-Note 'ReShade has not started with the game since this install. Start the game once, then run this check again.'
    } else {
        Say-Ok "ReShade last started with the game: $($logInfo.When.ToString('yyyy-MM-dd HH:mm')) (version $($logInfo.Version))."
    }

    Say ''
    if ($failed -gt 0) {
        $script:ExitCode = 1
        Say "  $failed check(s) failed. See the notes above." 'Red'
    } else {
        Say '  All installed files are in place.' 'Green'
    }
}

# ---------------------------------------------------------------------------
#  Uninstall
# ---------------------------------------------------------------------------

function Start-Uninstall {
    Say ''
    Say "  $ToolTitle $ToolVersion - uninstall ReShade + GPosingway" 'White'
    if ($DryRun) { Say '  PREVIEW MODE: nothing is changed.' 'Magenta' }
    Say ''
    $game = Select-GameFolder
    $record = Get-Record $game
    if (-not $record) {
        Stop-Here ("No install by this tool was found in $game. Nothing was removed. " +
                   'If ReShade was installed another way, use its own setup program to uninstall it.')
    }
    Wait-GameClosed $game

    $recordDir = Join-Path $game $RecordFolder
    $dxgi = Join-Path $game $record.reshadeFile
    $removeDll = $false
    if ($record.reshadeInstalled -and (Test-Path -LiteralPath $dxgi)) {
        if (Test-Fingerprint $dxgi $record.reshadeSha256) { $removeDll = $true }
        else { Say-Note "$($record.reshadeFile) has been modified since install and will be left in place." }
    }

    $extras = @('ReShade.log', 'ReShadePreset.ini') | Where-Object { Test-Path -LiteralPath (Join-Path $game $_) }
    # The screenshot folder this tool created is removed only when it is empty.
    $shots = [string](Get-Prop $record 'screenshotFolder' '')
    $shotsPath = $null
    $shotsEmpty = $false
    if ((Test-PlainName $shots) -and (Test-Path -LiteralPath (Join-Path $game $shots) -PathType Container)) {
        $shotsPath = Join-Path $game $shots
        $shotsEmpty = (@(Get-ChildItem -LiteralPath $shotsPath -Force).Count -eq 0)
    }
    Say '  Changes to be made in:'
    Say "    $game" 'White'
    if ($removeDll) { Say "    remove  $($record.reshadeFile)" }
    foreach ($name in $record.packItems) {
        if (Test-Path -LiteralPath (Join-Path $game $name)) { Say "    remove  $name" }
    }
    foreach ($name in $extras) { Say "    remove  $name  (created by ReShade)" }
    if ($shotsPath -and $shotsEmpty) { Say "    remove  $shots  (empty screenshot folder)" }
    elseif ($shotsPath) { Say "    keep    $shots  (your screenshots)" }
    $hasBackup = $record.backupFolder -and (Test-Path -LiteralPath $record.backupFolder)
    if ($hasBackup) {
        foreach ($name in $record.backedUp) { Say "    restore $name  (from backup)" }
    }
    Say ''
    Say-Note 'Presets saved in reshade-presets will also be removed.'
    if ($DryRun) { Say-Preview 'Preview complete. Nothing was changed.'; return }
    if (-not (Ask-YesNo '  Proceed?')) { Stop-Here 'No changes were made.' }
    if (-not (Test-CanWrite $game)) { Stop-Here (Get-CannotWriteText) }

    $script:ChangesStarted = $true
    if ($removeDll) { Remove-Item -LiteralPath $dxgi -Force; Say-Ok "Removed $($record.reshadeFile)." }
    foreach ($name in $record.packItems) {
        $path = Join-Path $game $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Say-Ok "Removed $name." }
    }
    foreach ($name in $extras) { Remove-Item -LiteralPath (Join-Path $game $name) -Force }
    if ($shotsPath -and $shotsEmpty) {
        # No -Recurse: if a file has appeared in it since, the folder stays.
        try { Remove-Item -LiteralPath $shotsPath -Force; Say-Ok "Removed $shots." }
        catch { $shotsEmpty = $false }
    }
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
        Say-Note 'Files from earlier installs (including saved presets) remain in:'
        Say "       $recordDir"
        Say '       Delete that folder when no longer needed.'
    }
    if ($shotsPath -and -not $shotsEmpty) {
        Say-Note 'Your screenshots were kept in:'
        Say "       $shotsPath"
    }

    Say ''
    Say '  Uninstall complete. The game folder has been restored.' 'Green'

    # Only this tool's own download folder is offered, never one given with -CacheDir.
    if ($OwnCache -and (Test-Path -LiteralPath $CacheDir)) {
        $kept = @(Get-ChildItem -LiteralPath $CacheDir -File -Force -ErrorAction SilentlyContinue)
        if ($kept.Count -gt 0) {
            $size = [long](($kept | Measure-Object -Property Length -Sum).Sum)
            Say ''
            if (Ask-YesNo -DefaultNo -Question ("  Delete the downloaded files ({0})?" -f (Format-Size $size))) {
                $stuck = 0
                foreach ($file in $kept) {
                    try { Remove-Item -LiteralPath $file.FullName -Force } catch { $stuck++ }
                }
                if ($stuck -eq 0) { Say-Ok 'Deleted.' }
                else { Say-Note "Could not delete $stuck file(s). Delete this folder by hand: $CacheDir" }
            } else {
                Say "  Kept in: $CacheDir"
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  Menu
# ---------------------------------------------------------------------------

# Returns 'install', 'preview', 'check', 'uninstall' or 'quit'.
function Read-MenuChoice {
    Say ''
    Say "  $ToolTitle $ToolVersion" 'White'
    Say '  ReShade + GPosingway setup for FINAL FANTASY XIV'
    if (-not (Test-Elevated)) {
        Say ''
        Say '  Running without administrator permission. Install and Uninstall will' 'DarkGray'
        Say '  only work if the game folder is not protected.' 'DarkGray'
    }
    Say ''
    Say '    1. Install or repair'
    Say '    2. Preview (changes nothing)'
    Say '    3. Check an existing install'
    Say '    4. Uninstall'
    Say '    Q. Quit'
    Say ''
    for ($try = 1; $try -le 5; $try++) {
        $answer = ([string](Read-Host '  Choose [1-4, Q]')).Trim()
        Write-Log "MENU -> $answer"
        if ($answer -eq '1') { return 'install' }
        if ($answer -eq '2') { return 'preview' }
        if ($answer -eq '3') { return 'check' }
        if ($answer -eq '4') { return 'uninstall' }
        if ($answer -match '^q') { return 'quit' }
    }
    return 'quit'
}

# ---------------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------------

if ($RequestAdmin) { exit (Request-Admin) }

try {
    Write-Log "=== $ToolName $ToolVersion started (DryRun=$DryRun, Uninstall=$Uninstall, Check=$Check) ==="
    Test-Environment
    Enter-SingleInstance
    if ($Menu) {
        $choice = Read-MenuChoice
        if ($choice -eq 'install')       { Start-Install }
        elseif ($choice -eq 'preview')   { $DryRun = $true; Start-Install }
        elseif ($choice -eq 'check')     { Start-Check }
        elseif ($choice -eq 'uninstall') { Start-Uninstall }
    }
    elseif ($Check)     { Start-Check }
    elseif ($Uninstall) { Start-Uninstall }
    else                { Start-Install }
} catch {
    $message = [string]$_.Exception.Message
    Write-Host ''
    if ($message.StartsWith($StopPrefix)) {
        Say ('  ' + $message.Substring($StopPrefix.Length)) 'Yellow'
    } else {
        Say '  Unexpected error. Stopped.' 'Red'
        Say "  $message" 'Red'
        if ($script:ChangesStarted) {
            Say '  The game folder may be partly changed. Run OpenShade.cmd and choose'
            Say '  Uninstall to restore it, or Install to try again.'
        } else {
            Say '  No changes were made to the game folder.'
        }
        Say "  Log: $LogPath"
        Say '  To report this: https://github.com/divinepleroma/openshade-xiv/issues'
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
