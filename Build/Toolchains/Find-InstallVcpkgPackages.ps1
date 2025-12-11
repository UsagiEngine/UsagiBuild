<#
.SYNOPSIS
    Searches for vcpkg packages (accepting feature brackets), deduplicates, highlights, and prompts for installation.
    
.EXAMPLE
    .\Find-InstallVcpkgPackage.ps1 imgui
#>
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$SearchQueries
)

# Configuration
$OverlayPath = "vcpkg-overlay-triplets"
$Triplet     = "x64-win-llvm-lto-static"
$CommonArgs  = @("--overlay-triplets=$OverlayPath", "--triplet=$Triplet")

# Dictionary to deduplicate results: Key = PackageName, Value = Full raw line
$uniqueResults = [Ordered]@{}

# --- Step 1: Search & Deduplicate ---
Write-Host ">>> Searching packages with triplet [$Triplet]..." -ForegroundColor Cyan

foreach ($query in $SearchQueries) {
    # Capture output
    $output = vcpkg search $query @CommonArgs 2>$null
    
    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        
        # Split: "name   version   description"
        $parts = $line.Trim() -split '\s+', 2
        $pkgName = $parts[0]
        
        # FIXED: Regex now permits brackets [ ] for feature packages
        if ($pkgName -match '^[a-z0-9][a-z0-9_\-\[\]]*$') {
            if (-not $uniqueResults.Contains($pkgName)) {
                $uniqueResults[$pkgName] = $line
            }
        }
    }
}

Write-Host "`nFound $($uniqueResults.Count) unique packages:`n"

# --- Step 2: Print with Highlighting ---
# Create regex for highlighting user queries
$escapedQueries = $SearchQueries | ForEach-Object { [Regex]::Escape($_) }
$highlightPattern = "(" + ($escapedQueries -join "|") + ")"

foreach ($line in $uniqueResults.Values) {
    # Split the line by the pattern.
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

# --- Step 3: Prompt ---
$packagesInput = Read-Host ">>> Enter packages to install (space-separated), or press Enter to skip"

if ([string]::IsNullOrWhiteSpace($packagesInput)) {
    Write-Host "No packages selected. Exiting." -ForegroundColor Gray
    return
}

$packagesToInstall = $packagesInput -split '\s+' | Where-Object { $_ -ne "" }

# --- Step 4: Install ---
Write-Host "`n>>> Installing: $($packagesToInstall -join ', ')..." -ForegroundColor Cyan
vcpkg install $packagesToInstall @CommonArgs --recurse

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n>>> Installation Complete." -ForegroundColor Green
} else {
    Write-Host "`n>>> Installation Failed." -ForegroundColor Red
}
