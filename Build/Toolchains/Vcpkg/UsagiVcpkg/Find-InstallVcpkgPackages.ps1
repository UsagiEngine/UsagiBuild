<#
.SYNOPSIS
    Searches for vcpkg packages (Exact Match), highlighting results and prompting.
    Supports Unattended mode and Resuming from lock files.
#>
param(
    [switch]$ForceReinstall,
    [switch]$Unattended, # Skips search, installs input exactly (BestEffort)
    [switch]$Resume,     # Resumes from lock file

    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$SearchQueries
)

Import-Module "$PSScriptRoot\UsagiVcpkg.psm1" -Force

$Config = Get-UsagiVcpkgConfig -ScriptRoot $PSScriptRoot
$TargetTriplet = $Config.DefaultTriplet
$CommonArgs = $Config.CommonArgs + @("--triplet=$TargetTriplet")

# --- Helper: Parse & Normalize Input ---
# "pkg [ a, b ]" -> Name="pkg", Spec="pkg[a,b]"
function Get-NormalizedSpec ($rawInput) {
    if ($rawInput -match '^([a-z0-9-]+)(?:\[([^\]]+)\])?$') {
        $name = $matches[1]
        $feats = if ($matches[2]) {
            ($matches[2] -split ',' | ForEach-Object { $_.Trim() }) -join ','
        } else { $null }

        $spec = if ($feats) { "$name[$feats]" } else { $name }
        return @{ Name = $name; Spec = $spec }
    }
    return @{ Name = $rawInput; Spec = $rawInput }
}

# --- Mode: Resume ---
if ($Resume) {
    Invoke-UsagiVcpkgInstall `
        -Resume `
        -Triplet $TargetTriplet `
        -CommonArgs $Config.CommonArgs `
        -Recurse
    return
}

# --- Mode: Unattended (Best Effort) ---
if ($Unattended) {
    Write-Host ">>> Unattended Mode: processing $($SearchQueries.Count) queries..." `
        -ForegroundColor Cyan

    $installList = @()
    foreach ($q in $SearchQueries) {
        $norm = Get-NormalizedSpec $q
        $installList += $norm.Spec
    }

    Invoke-UsagiVcpkgInstall `
        -Packages $installList `
        -Triplet $TargetTriplet `
        -CommonArgs $Config.CommonArgs `
        -Recurse
    return
}

# --- Mode: Interactive Search (Exact Match) ---
Write-Host ">>> Searching packages [$TargetTriplet]..." -ForegroundColor Cyan

$exactMatches = [Ordered]@{} # Key=PkgName, Value=LogLine
$installMap   = @{}          # Key=PkgName, Value=InstallSpec (with features)

foreach ($query in $SearchQueries) {
    $norm = Get-NormalizedSpec $query
    $baseName = $norm.Name

    # Search for the base name
    $output = vcpkg search $baseName @CommonArgs 2>$null

    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line.Trim() -split '\s+', 2
        $foundName = $parts[0]

        # EXACT MATCH FILTER
        # If input is 'eigen3', ignore 'highfive[eigen3]'
        if ($foundName -eq $baseName) {
            if (-not $exactMatches.Contains($baseName)) {
                $exactMatches[$baseName] = $line
                # Map the base name back to the user's requested features
                $installMap[$baseName]   = $norm.Spec
            }
            break # Found our exact match, stop scanning this query's results
        }
    }
}

# --- Print Results ---
if ($exactMatches.Count -eq 0) {
    Write-Host "No exact matches found." -ForegroundColor Yellow
    return
}

Write-Host "`nFound $($exactMatches.Count) exact matches:`n"
$escapedQueries = $SearchQueries | ForEach-Object { [Regex]::Escape($_) }
$highlightPattern = "(" + ($escapedQueries -join "|") + ")"

foreach ($line in $exactMatches.Values) {
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

# --- Prompt ---
$inputStr = Read-Host ">>> Enter packages (space-separated), Input * for all matches, or Ctrl+C to exit"
if ([string]::IsNullOrWhiteSpace($inputStr)) { return }

$rawTokens = $inputStr -split '\s+' | Where-Object { $_ -ne "" }
$packagesToInstall = @()

# --- Expand Wildcards & Map Features ---
foreach ($token in $rawTokens) {
    if ($token -eq '*') {
        # * -> Install all found packages using the Requested Specs (features preserved)
        foreach ($key in $exactMatches.Keys) {
            $packagesToInstall += $installMap[$key]
        }
        Write-Host "    [Expander] * -> All ($($exactMatches.Count)) matched packages" `
            -ForegroundColor DarkGray
    } else {
        # Check if the token matches a found package key to restore features
        # e.g. User types "imgui" -> Script restores "imgui[docking]" if that was the query
        if ($installMap.ContainsKey($token)) {
            $packagesToInstall += $installMap[$token]
        } else {
            # User typed something new/different, use as-is
            $packagesToInstall += $token
        }
    }
}

$packagesToInstall = $packagesToInstall | Select-Object -Unique

# --- Reinstall Logic ---
if ($ForceReinstall) {
    $baseNames = $packagesToInstall |
        ForEach-Object { ($_ -split '\[')[0] } |
        Select-Object -Unique

    Write-Host "`n>>> ForceReinstall: Removing $baseNames..." `
        -ForegroundColor Yellow

    vcpkg remove $baseNames --recurse @CommonArgs
}

# --- Install ---
Invoke-UsagiVcpkgInstall `
    -Packages $packagesToInstall `
    -Triplet $TargetTriplet `
    -CommonArgs $Config.CommonArgs `
    -Recurse
