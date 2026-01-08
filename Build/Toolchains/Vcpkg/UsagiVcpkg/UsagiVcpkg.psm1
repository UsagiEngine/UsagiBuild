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

# --- Dependency Resolution ---

function Resolve-VcpkgRootRequirements {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IDictionary]$PackageMap, # Name -> Features

        [string]$TargetTriplet,
        [string[]]$CommonArgs
    )

    Write-Host ">>> Analyzing dependency graph..." -ForegroundColor Cyan

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

    $nonRoots = [System.Collections.Generic.HashSet[string]]::new()
    $total = $candidates.Count
    $current = 0

    foreach ($candidate in $candidates) {
        $current++
        Write-Progress -Activity "Analyzing Dependencies" `
            -Status "Checking $candidate" `
            -PercentComplete (($current / $total) * 100)

        $info = vcpkg depend-info $candidate `
            --triplet $TargetTriplet `
            @CommonArgs 2>$null

        foreach ($line in $info) {
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
        [switch]$DryRun,
        [switch]$BestEffort=$true, # Installs one-by-one, ignoring failures
        [switch]$Resume            # Loads from lock file
    )

    $lockFileName = "vcpkg-${Triplet}.lock.yaml"
    $lockFilePath = Join-Path $PWD $lockFileName

    # --- Lock File / Resume Logic ---
    if ($Resume) {
        if (Test-Path $lockFilePath) {
            Write-Host ">>> Resuming from $lockFileName..." -ForegroundColor Yellow
            $content = Get-Content $lockFilePath
            # Simple YAML parsing: Extract lines starting with "- "
            $Packages = $content | ForEach-Object {
                if ($_ -match '^-\s+(.*)$') { $matches[1] }
            }
        } else {
            Write-Host ">>> No lock file ($lockFileName) found to resume." `
                -ForegroundColor Red
            return
        }
    } elseif (-not $DryRun -and $Packages.Count -gt 0) {
        # Create/Overwrite Lock File
        $yamlContent = $Packages | ForEach-Object { "- $_" }
        $yamlContent | Set-Content $lockFilePath
    }

    if ($Packages.Count -eq 0) {
        Write-Host "No packages to install." -ForegroundColor Yellow
        return
    }

    # --- Best Effort (Iterative) ---
    if ($BestEffort) {
        $failed = @()
        $remaining = [System.Collections.Generic.List[string]]::new($Packages)

        Write-Host "`n>>> Starting Best-Effort Installation ($($remaining.Count) items)..." `
            -ForegroundColor Cyan

        foreach ($pkg in $Packages) {
            Write-Host "`n>>> [BestEffort] Installing $pkg..." -ForegroundColor Cyan
            $cmdArgs = @("install", $pkg, "--triplet=$Triplet") + $CommonArgs
            if ($Recurse) { $cmdArgs += "--recurse" }

            if ($DryRun) {
                Write-Host "vcpkg $cmdArgs" -ForegroundColor Gray
            } else {
                vcpkg @cmdArgs

                if ($LASTEXITCODE -eq 0) {
                    # Update Lock File: Remove successful package
                    $remaining.Remove($pkg) | Out-Null
                    if ($remaining.Count -eq 0) {
                        Remove-Item $lockFilePath -ErrorAction SilentlyContinue
                    } else {
                        $yamlContent = $remaining | ForEach-Object { "- $_" }
                        $yamlContent | Set-Content $lockFilePath
                    }
                } else {
                    Write-Host ">>> Failed to install $pkg. Skipping." -ForegroundColor Red
                    $failed += $pkg
                }
            }
        }

        if ($failed.Count -gt 0) {
            Write-Host "`n>>> BestEffort finished with $($failed.Count) failures." `
                -ForegroundColor Yellow
            Write-Host "    Failed: $($failed -join ', ')" -ForegroundColor Gray
            Write-Host "    Pending packages are saved in $lockFileName" -ForegroundColor Gray
        } else {
            Write-Host "`n>>> BestEffort All Success." -ForegroundColor Green
        }

    # --- Standard (Batch) ---
    } else {
        $cmdArgs = @("install") + $Packages + "--triplet=$Triplet" + $CommonArgs
        if ($Recurse) { $cmdArgs += "--recurse" }

        Write-Host "`n>>> Installation Command:" -ForegroundColor Green
        Write-Host "vcpkg $cmdArgs" -ForegroundColor Gray

        if ($DryRun) {
            Write-Host ">>> (Dry Run) Skipping execution." -ForegroundColor Yellow
        } else {
            vcpkg @cmdArgs
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`n>>> Success." -ForegroundColor Green
                Remove-Item $lockFilePath -ErrorAction SilentlyContinue
            } else {
                Write-Host "`n>>> Failed. Progress saved to $lockFileName" `
                    -ForegroundColor Red
            }
        }
    }
}
