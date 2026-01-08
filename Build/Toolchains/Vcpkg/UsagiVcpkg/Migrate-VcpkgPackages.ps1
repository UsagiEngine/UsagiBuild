<#
.SYNOPSIS
    Migrates packages from one triplet to another.
    Automatically merges feature flags.
    Detects and installs only root requirements.

.EXAMPLE
    .\Migrate-VcpkgPackages.ps1
    .\Migrate-VcpkgPackages.ps1 -SourceTriplet x64-windows -DryRun
#>
param(
    [string]$SourceTriplet,
    [string]$TargetTriplet,
    [string]$TripletOverlay,
    [switch]$DryRun,
    [switch]$Resume # Resume from vcpkg-TRIPLET.lock.yaml
)

Import-Module "$PSScriptRoot\UsagiVcpkg.psm1" -Force

$Config = Get-UsagiVcpkgConfig -ScriptRoot $PSScriptRoot

# Apply configuration defaults if parameters are missing
if (-not $SourceTriplet) { $SourceTriplet = $Config.SourceTriplet }
if (-not $TargetTriplet) { $TargetTriplet = $Config.DefaultTriplet }

# If user overrides overlay, update config and regenerate common args
if ($TripletOverlay) {
    $Config.OverlayPath = $TripletOverlay
    $Config.CommonArgs = @("--overlay-triplets=$($Config.OverlayPath)")
}

$CommonArgs = $Config.CommonArgs

# --- Step 0: Resume Check ---
if ($Resume) {
    Write-Host ">>> Resuming migration for $TargetTriplet..." -ForegroundColor Magenta
    Invoke-UsagiVcpkgInstall `
        -Resume `
        -Triplet $TargetTriplet `
        -CommonArgs $CommonArgs `
        -Recurse
    return
}

Write-Host ">>> Usagi Vcpkg Migration 🍓" -ForegroundColor Magenta
Write-Host "    Source: $SourceTriplet" -ForegroundColor Gray
Write-Host "    Target: $TargetTriplet" -ForegroundColor Gray
Write-Host "    Overlay: $($Config.OverlayPath)" -ForegroundColor Gray

# --- Step 1: List & Parse ---
Write-Host "`n>>> scanning installed packages ($SourceTriplet)..." `
    -ForegroundColor Cyan

$listOutput = vcpkg list --classic --x-full-desc `
    --triplet $SourceTriplet @CommonArgs 2>$null

if ($null -eq $listOutput -or $listOutput.Count -eq 0) {
    Write-Host "No packages found for triplet $SourceTriplet. Nothing to migrate." `
        -ForegroundColor Yellow
    return
}

$packageMap = ConvertFrom-VcpkgListOutput `
    -Output $listOutput `
    -FilterTriplet $SourceTriplet

if ($packageMap.Count -eq 0) {
    Write-Host "No packages found for triplet $SourceTriplet." `
        -ForegroundColor Yellow
    return
}

Write-Host "Found $($packageMap.Count) unique packages (features merged)." `
    -ForegroundColor Green

# --- Step 2: Resolve Roots ---
$roots = Resolve-VcpkgRootRequirements `
    -PackageMap $packageMap `
    -TargetTriplet $TargetTriplet `
    -CommonArgs $CommonArgs

Write-Host "`n>>> Root Requirements Identified ($($roots.Count)): " `
    -ForegroundColor Cyan

foreach ($r in $roots) {
    Write-Host "    $r" -ForegroundColor White
}

$hiddenCount = $packageMap.Count - $roots.Count
if ($hiddenCount -gt 0) {
    Write-Host "    ... plus $hiddenCount dependencies (implicitly included)" `
        -ForegroundColor DarkGray
}

# --- Step 3: Install ---
$confirm = Read-Host "`n>>> Proceed with migration? (y/n)"
if ($confirm -eq 'y') {
    Invoke-UsagiVcpkgInstall `
        -Packages $roots `
        -Triplet $TargetTriplet `
        -CommonArgs $CommonArgs `
        -Recurse `
        -DryRun:$DryRun
} else {
    Write-Host "Cancelled." -ForegroundColor Yellow
}
