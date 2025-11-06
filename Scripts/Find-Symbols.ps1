<#
.SYNOPSIS
    Searches all .lib files in the latest MSVC toolset directory for a specific symbol pattern.

.DESCRIPTION
    Finds the latest Visual Studio installation using vswhere.exe,
    locates the MSVC lib directory for the specified architecture,
    and then runs "dumpbin /symbols /exports" on each .lib file,
    filtering the output for a user-specified string pattern (case-sensitive).

.PARAMETER Pattern
    The string pattern to search for within the dumpbin output. This argument is mandatory.
    (e.g., "ExceptionPtr", "mainCRTStartup")

.PARAMETER Architecture
    The target architecture library directory to search (e.g., "x64", "x86", "arm64").
    Defaults to "x64".

.EXAMPLE
    .\Find-Symbols.ps1 -Pattern "ExceptionPtr"
    (Searches the x64 lib folder)

.EXAMPLE
    .\Find-Symbols.ps1 "mainCRTStartup" -Architecture x86
    (Searches the x86 lib folder)
#>
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Pattern,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet("x64", "x86", "arm64")]
    [string]$Architecture = "x64"
)

# --- Find Visual Studio Installation ---
$vsInstallPath = $null
$dumpbinExe = "dumpbin" # Assume it's in the path

try {
    $vsInstallPath = & "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath -nologo
    if (-not $vsInstallPath) { throw "vswhere.exe did not return an installation path." }
} catch {
    Write-Warning "vswhere.exe not found or failed. Please run this from a Visual Studio Developer Command Prompt if you want to search the MSVC lib path."
    # We can still proceed if dumpbin is in the path and user wants to search '.'
}

# --- Find dumpbin.exe ---
if (-not (Get-Command $dumpbinExe -ErrorAction SilentlyContinue)) {
    Write-Warning "dumpbin.exe not found in your PATH."
    if ($vsInstallPath) {
        # Try to find it in the VS install path
        try {
            $dumpbinPath = Get-ChildItem -Path (Join-Path $vsInstallPath "VC\Tools\MSVC") -Filter "dumpbin.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($dumpbinPath) {
                Write-Host "Found dumpbin at: $($dumpbinPath.FullName)"
                $dumpbinExe = $dumpbinPath.FullName
            } else {
                throw "Could not automatically locate dumpbin.exe in $vsInstallPath."
            }
        } catch {
            Write-Error "Failed to find dumpbin.exe. Please set up your environment."
            return
        }
    } else {
         Write-Error "Cannot find dumpbin.exe. Please run from a Developer Command Prompt."
         return
    }
}

# --- Find MSVC Library Path ---
$libPath = $null
if ($vsInstallPath) {
    try {
        $msvcToolsPath = Join-Path $vsInstallPath "VC\Tools\MSVC"
        if (-not (Test-Path $msvcToolsPath)) { throw "MSVC tools path not found at $msvcToolsPath" }

        $latestMsvcVersionPath = Get-ChildItem -Path $msvcToolsPath -Directory | Sort-Object Name -Descending | Select-Object -First 1 | Select-Object -ExpandProperty FullName
        if (-not $latestMsvcVersionPath) { throw "No MSVC toolset version found in $msvcToolsPath" }

        $libPath = Join-Path $latestMsvcVersionPath "lib\$Architecture"
        if (-not (Test-Path $libPath)) { throw "Lib path not found at $libPath" }
    } catch {
        Write-Error "Failed to automatically find MSVC lib directory: $_"
        Write-Warning "Falling back to searching current directory '.'"
        $libPath = "."
    }
} else {
    Write-Warning "No Visual Studio installation found by vswhere. Searching current directory '.'"
    $libPath = "."
}


Write-Host "Searching for '$Pattern' in all .lib files in '$libPath'..."

Get-ChildItem -Path $libPath -Filter "*.lib" -File | ForEach-Object {
    $fileName = $_.Name
    $filePath = $_.FullName

    # 1. Execute dumpbin, merging all streams (stdout and stderr)
    # Using $dumpbinExe variable to hold the path or command
    $dumpbinOutput = & $dumpbinExe /symbols /exports $filePath *>&1

    # 2. Filter the output strings using the provided pattern
    $dumpbinOutput | Select-String -Pattern $Pattern -CaseSensitive | ForEach-Object {
        # 3. Output the result, prefixing the filename
        "[$fileName]: $($_.Line)"
    }
}
