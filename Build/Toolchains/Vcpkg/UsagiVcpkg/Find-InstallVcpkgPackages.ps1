<#
.SYNOPSIS
    Searches for vcpkg packages, highlights results, and prompts.
    Uses the UsagiVcpkg shared module.
#>
param(
    [Parameter(Mandatory=$false)]
    [switch]$ForceReinstall,

    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$SearchQueries
)

Import-Module "$PSScriptRoot\UsagiVcpkg.psm1" -Force

$Config = Get-UsagiVcpkgConfig -ScriptRoot $PSScriptRoot

# Default to the libc++ triplet for new installs
$TargetTriplet = $Config.DefaultTriplet
$CommonArgs = $Config.CommonArgs + @("--triplet=$TargetTriplet")

# --- Step 1: Search ---
Write-Host ">>> Searching packages [$TargetTriplet]..." -ForegroundColor Cyan
$uniqueResults = [Ordered]@{}

foreach ($query in $SearchQueries) {
    $output = vcpkg search $query @CommonArgs 2>$null
    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split '\s+', 2
        $pkgName = $parts[0]
        # Store unique lines
        if (-not $uniqueResults.Contains($pkgName)) {
            $uniqueResults[$pkgName] = $line
        }
    }
}

# --- Step 2: Print & Highlight ---
Write-Host "`nFound $($uniqueResults.Count) unique packages:`n"
$escapedQueries = $SearchQueries | ForEach-Object { [Regex]::Escape($_) }
$highlightPattern = "(" + ($escapedQueries -join "|") + ")"

foreach ($line in $uniqueResults.Values) {
    $tokens = [Regex]::Split($line, $highlightPattern, "IgnoreCase")
    foreach ($token in $tokens) {
        if ($token -match $highlightPattern) {
            Write-Host $token -NoNewline -ForegroundColor Cyan
        } else {
            Write-Host $token -NoNewline
        }
    }
    Write-Host ""
}
Write-Host "`n"

# --- Step 3: Prompt & Install ---
$input = Read-Host ">>> Enter packages (space-separated) or Enter to skip"
if ([string]::IsNullOrWhiteSpace($input)) { return }

$packages = $input -split '\s+' | Where-Object { $_ -ne "" }

if ($ForceReinstall) {
    $baseNames = $packages |
        ForEach-Object { ($_ -split '\[')[0] } |
        Select-Object -Unique

    Write-Host "`n>>> ForceReinstall: Removing $baseNames..." `
        -ForegroundColor Yellow

    vcpkg remove $baseNames --recurse @CommonArgs
}

Invoke-UsagiVcpkgInstall `
    -Packages $packages `
    -Triplet $TargetTriplet `
    -CommonArgs $Config.CommonArgs `
    -Recurse
