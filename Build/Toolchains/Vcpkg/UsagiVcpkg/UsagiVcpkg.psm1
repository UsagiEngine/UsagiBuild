# =============================================================================
# UsagiVcpkg.psm1
# Shared logic for UsagiBuild Vcpkg operations (Search, Install, Migration).
# =============================================================================

# --- Configuration Helpers ---

function Get-UsagiVcpkgConfig {
    param([string]$ScriptRoot)

    # Defaults tailored for your UsagiBuild environment
    # User requested path relative to parent: ..\vcpkg-overlay-triplets
    $overlayPath = Join-Path $ScriptRoot "..\vcpkg-overlay-triplets"

    # Resolve to absolute path to avoid ambiguity with relative paths in vcpkg calls
    if (Test-Path $overlayPath) {
        $overlayPath = Resolve-Path $overlayPath
    } else {
        # Fallback if it doesn't exist yet (keeps the logical path)
        $overlayPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($overlayPath)
    }

    return [Ordered]@{
        OverlayPath     = $overlayPath
        DefaultTriplet  = "x64-win-llvm-lto-libcxx-static"
        SourceTriplet   = "x64-win-llvm-lto-static"
        CommonArgs      = @("--overlay-triplets=$overlayPath")
    }
}

# --- Parsing Logic ---

function ConvertFrom-VcpkgListOutput {
    param(
        [Parameter(Mandatory=$false)]
        [string[]]$Output,

        [string]$FilterTriplet
    )

    $results = @{} # Key: PackageName, Value: HashSet<Features>

    if ($null -eq $Output -or $Output.Count -eq 0) {
        return $results
    }

    foreach ($line in $Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Regex to capture: Name, Optional [features], and Triplet
        # Example: imgui[core,docking]:x64-windows
        if ($line -match '^([a-z0-9-]+)(?:\[([^\]]+)\])?:([a-z0-9-]+)') {
            $name     = $matches[1]
            $features = $matches[2]
            $triplet  = $matches[3]

            if (-not [string]::IsNullOrEmpty($FilterTriplet)) {
                if ($triplet -ne $FilterTriplet) { continue }
            }

            if (-not $results.Contains($name)) {
                $results[$name] = `
                    [System.Collections.Generic.HashSet[string]]::new()
            }

            if (-not [string]::IsNullOrEmpty($features)) {
                $feats = $features -split ','
                foreach ($f in $feats) {
                    $null = $results[$name].Add($f.Trim())
                }
            }
        }
    }
    return $results
}

# --- Dependency Resolution (The "Root" Logic) ---

function Resolve-VcpkgRootRequirements {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IDictionary]$PackageMap, # Name -> Features

        [string]$TargetTriplet,
        [string[]]$CommonArgs
    )

    Write-Host ">>> Analyzing dependency graph..." -ForegroundColor Cyan

    # 1. Build a list of candidate specs "pkg[f1,f2]"
    $candidates = @()
    foreach ($key in $PackageMap.Keys) {
        $features = $PackageMap[$key]
        $spec = $key
        if ($features.Count -gt 0) {
            $spec += "[" + ($features -join ",") + "]"
        }
        $candidates += $spec
    }

    if ($candidates.Count -eq 0) { return @() }

    # 2. Identify dependencies
    $nonRoots = [System.Collections.Generic.HashSet[string]]::new()
    $total = $candidates.Count
    $current = 0

    foreach ($candidate in $candidates) {
        $current++
        Write-Progress -Activity "Analyzing Dependencies" `
            -Status "Checking $candidate" `
            -PercentComplete (($current / $total) * 100)

        # 'depend-info' outputs lines like: candidate: dep1, dep2, ...
        $info = vcpkg depend-info $candidate `
            --triplet $TargetTriplet `
            @CommonArgs 2>$null

        foreach ($line in $info) {
            # Looking for dependencies usually after the colon
            if ($line -match ':\s*(.+)$') {
                $deps = $matches[1] -split ',\s*'
                foreach ($dep in $deps) {
                    $depName = $dep -split '\[' | Select-Object -First 1
                    if ($depName -ne $candidate -and `
                        $PackageMap.Contains($depName)) {
                        $null = $nonRoots.Add($depName)
                    }
                }
            }
        }
    }
    Write-Progress -Activity "Analyzing Dependencies" -Completed

    # 3. Filter Roots
    $roots = @()
    foreach ($candidate in $candidates) {
        $name = $candidate -split '\[' | Select-Object -First 1
        if (-not $nonRoots.Contains($name)) {
            $roots += $candidate
        }
    }

    return $roots
}

# --- Install Helper ---

function Invoke-UsagiVcpkgInstall {
    param(
        [string[]]$Packages,
        [string]$Triplet,
        [string[]]$CommonArgs,
        [switch]$Recurse,
        [switch]$DryRun
    )

    if ($Packages.Count -eq 0) {
        Write-Host "No packages to install." -ForegroundColor Yellow
        return
    }

    $cmdArgs = @("install") + $Packages + `
               "--triplet=$Triplet" + $CommonArgs
    if ($Recurse) { $cmdArgs += "--recurse" }

    Write-Host "`n>>> Installation Command:" -ForegroundColor Green
    Write-Host "vcpkg $cmdArgs" -ForegroundColor Gray

    if ($DryRun) {
        Write-Host ">>> (Dry Run) Skipping execution." -ForegroundColor Yellow
    } else {
        vcpkg @cmdArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n>>> Success." -ForegroundColor Green
        } else {
            Write-Host "`n>>> Failed." -ForegroundColor Red
        }
    }
}
