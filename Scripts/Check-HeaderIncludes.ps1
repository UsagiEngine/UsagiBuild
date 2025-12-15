<#
.SYNOPSIS
    Checks if C++ headers are self-contained by attempting to compile them individually.
    
.DESCRIPTION
    Located in UsagiBuild/Scripts.
    Uses UsagiBuild.sln (in parent dir) to resolve project paths.
    Compiles headers using MSBuild with /TP (Treat as C++) to verify missing #includes.

.EXAMPLE
    .\Check-HeaderIncludes.ps1 -ProjectName "Core.Reflect" -HeaderPath "Public\Reflect.hpp"
    .\Check-HeaderIncludes.ps1 -ProjectName "Core.Reflect" -HeaderPath "Source" -Recursive
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory=$true)]
    [string]$HeaderPath,
    
    [switch]$Recursive,
    
    [string]$Configuration = "Debug|x64"
)

# -----------------------------------------------------------------------------
# 1. Setup & Helpers
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptBindingContext.ScriptRoot
# Fallback if running manually outside of a module context
if (-not $ScriptRoot) { $ScriptRoot = $PSScriptRoot }

function Write-Log ($Message, $Color="White", $Level="INFO") {
    $Time = Get-Date -Format "HH:mm:ss"
    Write-Host "[$Time][$Level] $Message" -ForegroundColor $Color
}

function Write-ErrorLog ($Message) { Write-Log $Message "Red" "ERROR" }
function Write-SuccessLog ($Message) { Write-Log $Message "Green" "OK" }

# -----------------------------------------------------------------------------
# 2. Locate MSBuild
# -----------------------------------------------------------------------------

Write-Log "Locating MSBuild..." "Cyan"

# Try vswhere first (standard way to find VS instances)
$VSWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$MSBuildPath = $null

if (Test-Path $VSWherePath) {
    $MSBuildPath = & $VSWherePath -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe
}

# Fallback to hardcoded path provided in prompt
if (-not $MSBuildPath -or -not (Test-Path $MSBuildPath)) {
    $FallbackPath = "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\amd64\MSBuild.exe"
    if (Test-Path $FallbackPath) {
        $MSBuildPath = $FallbackPath
    } else {
        # Try Community edition fallback just in case
        $CommunityPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe"
        if (Test-Path $CommunityPath) { $MSBuildPath = $CommunityPath }
    }
}

if (-not $MSBuildPath) {
    Write-ErrorLog "Critical: MSBuild.exe not found."
    exit 1
}
Write-Log "Found MSBuild: $MSBuildPath" "Gray"

# -----------------------------------------------------------------------------
# 3. Parse Configuration
# -----------------------------------------------------------------------------

# Split "Debug|x64" into "Debug" and "x64"
if ($Configuration -match "(.+)\|(.+)") {
    $ConfigProp = $Matches[1]
    $PlatProp = $Matches[2]
} else {
    # Default assumptions if format doesn't match
    $ConfigProp = $Configuration
    $PlatProp = "x64"
}
Write-Log "Target: Configuration=$ConfigProp, Platform=$PlatProp" "Gray"

# -----------------------------------------------------------------------------
# 4. Locate Project via SLN
# -----------------------------------------------------------------------------

$SolutionPath = Join-Path $ScriptRoot "..\UsagiBuild.sln" | Resolve-Path
if (-not (Test-Path $SolutionPath)) {
    Write-ErrorLog "Solution file not found at: $SolutionPath"
    exit 1
}

Write-Log "Scanning solution: $($SolutionPath.Path)" "Cyan"

# Regex to parse .sln format: Project("{GUID}") = "Name", "Path", "{GUID}"
$SlnContent = Get-Content $SolutionPath
$ProjectPattern = 'Project\("\{.*?\}"\)\s*=\s*"' + [Regex]::Escape($ProjectName) + '",\s*"(.*?)",'

$ProjectRelPath = $null
foreach ($line in $SlnContent) {
    if ($line -match $ProjectPattern) {
        $ProjectRelPath = $Matches[1]
        break
    }
}

if (-not $ProjectRelPath) {
    Write-ErrorLog "Project '$ProjectName' not found in UsagiBuild.sln."
    exit 1
}

# Resolve absolute path to .vcxproj
$SolutionDir = Split-Path $SolutionPath
$ProjectFullPath = Join-Path $SolutionDir $ProjectRelPath | Resolve-Path
$ProjectDir = Split-Path $ProjectFullPath

Write-Log "Located Project: $ProjectFullPath" "Green"

# -----------------------------------------------------------------------------
# 5. Resolve Targets (Headers)
# -----------------------------------------------------------------------------

# Force path resolution relative to $ProjectDir unless absolute
if ([System.IO.Path]::IsPathRooted($HeaderPath)) {
    $ResolvedHeaderRoot = $HeaderPath
} else {
    $ResolvedHeaderRoot = Join-Path $ProjectDir $HeaderPath
}

# Validate existence before switching context
if (-not (Test-Path $ResolvedHeaderRoot)) {
    Write-ErrorLog "Header path not found: $ResolvedHeaderRoot"
    Write-ErrorLog "(Interpreted relative to Project Root: $ProjectDir)"
    exit 1
}

# Change WD to Project Dir so MSBuild paths work
Push-Location $ProjectDir

$TargetFiles = @()

if ((Test-Path $ResolvedHeaderRoot -PathType Container)) {
    # Directory Mode
    Write-Log "Scanning directory '$ResolvedHeaderRoot' (Recursive=$Recursive)..." "Cyan"
    $RecurseFlag = if ($Recursive) { @("-Recurse") } else { @() }
    
    $TargetFiles = Get-ChildItem -Path $ResolvedHeaderRoot -Include "*.h", "*.hpp" @RecurseFlag | Select-Object -ExpandProperty FullName
} else {
    # Single File Mode
    $TargetFiles = @( (Resolve-Path $ResolvedHeaderRoot).Path )
}

if ($TargetFiles.Count -eq 0) {
    Write-Log "No header files found to check." "Yellow"
    Pop-Location
    exit 0
}

# -----------------------------------------------------------------------------
# 6. Execution Loop
# -----------------------------------------------------------------------------

$FailedCount = 0
$TotalCount = $TargetFiles.Count
$CurrentIdx = 0

Write-Log "Starting validation for $TotalCount files..." "Cyan"
Write-Log "---------------------------------------------------" "Gray"

foreach ($File in $TargetFiles) {
    $CurrentIdx++
    $FileName = Split-Path $File -Leaf
    Write-Host "[$CurrentIdx/$TotalCount] Checking: $FileName ... " -NoNewline
    
    $CmdArgs = @(
        $ProjectFullPath,
        "/nologo",
        "/t:ClCompile",
        "/p:Configuration=$ConfigProp",
        "/p:Platform=$PlatProp",
        "/p:SelectedFiles=$File",
        "/p:PrecompiledHeader=NotUsing",
        "/p:AdditionalOptions='/TP'",
        "/v:q",
        "/clp:ErrorsOnly"
    )
    
    $Process = Start-Process -FilePath $MSBuildPath -ArgumentList $CmdArgs -Wait -NoNewWindow -PassThru
    
    if ($Process.ExitCode -eq 0) {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "FAIL" -ForegroundColor Red
        $FailedCount++
        Write-Log "Detailed errors for $FileName should appear above." "Red" "FAIL"
    }
}

Pop-Location

Write-Log "---------------------------------------------------" "Gray"
if ($FailedCount -eq 0) {
    Write-SuccessLog "All $TotalCount headers validated successfully."
} else {
    Write-ErrorLog "Validation finished. $FailedCount / $TotalCount headers failed compilation."
    exit $FailedCount
}
