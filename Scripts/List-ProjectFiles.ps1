<#
.SYNOPSIS
Lists files from specific projects in the UsagiBuild workspace, with advanced filtering and task merging.

.DESCRIPTION
This script parses UsagiBuild.slnx to resolve project names to their .vcxproj files,
filters their source files based on source, extension, and git status, and outputs
a markdown checklist grouped by project. It can optionally merge existing pipeline
checklist items.

.PARAMETER Projects
An array of project names (without the .vcxproj extension) to query.

.PARAMETER SourceFilter
Filters which files to consider:
- 'all': All .cpp/.hpp files under the project's directory.
- 'project': Only files explicitly included in the .vcxproj (ClCompile/ClInclude).
- 'excluded': Files in the directory but NOT in the .vcxproj.

.PARAMETER FileFilter
Filters by file extension ('hpp', 'cpp', or 'all').

.PARAMETER GitFilter
Filters by git status:
- 'all': No git filtering.
- 'modified': Only files that are modified, added, etc.
- 'untracked': Only files that are untracked.

.PARAMETER CopyToClipboard
If specified, the output is copied to the clipboard.

.PARAMETER MergeEntries
If true (default), the script reads pipeline input for existing markdown checklist items and merges them.

.PARAMETER InputObject
Pipeline input containing markdown checklist text.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [string[]]$Projects,

    [Parameter(Mandatory=$false)]
    [ValidateSet('all','project','excluded')]
    [string]$SourceFilter = 'all',

    [Parameter(Mandatory=$false)]
    [ValidateSet('hpp','cpp','all')]
    [string]$FileFilter = 'all',

    [Parameter(Mandatory=$false)]
    [ValidateSet('all','modified','untracked')]
    [string]$GitFilter = 'all',

    [Parameter(Mandatory=$false)]
    [switch]$CopyToClipboard,

    [Parameter(Mandatory=$false)]
    [switch]$MergeEntries = $true,

    [Parameter(ValueFromPipeline=$true)]
    [string]$InputObject
)

begin {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = $PWD.Path }
    
    $workspaceRoot = (git -C $scriptDir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceRoot)) {
        Write-Error "Could not determine workspace root using Git."
        exit 1
    }
    $workspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot)

    $pipedLines = [System.Collections.Generic.List[string]]::new()
    
    # Attempt to load PSEverything for better file resolution
    Import-Module PSEverything -ErrorAction SilentlyContinue
}

process {
    if ($null -ne $InputObject) {
        foreach ($line in $InputObject -split '\r?\n') {
            $pipedLines.Add($line)
        }
    }
}

end {
    # 1. Parse UsagiBuild.slnx
    $slnxPath = Join-Path $workspaceRoot "UsagiBuild.slnx"
    if (-not (Test-Path $slnxPath)) {
        Write-Error "Cannot find UsagiBuild.slnx at $workspaceRoot"
        exit 1
    }

    $slnxContent = Get-Content $slnxPath -Raw
    $projectMap = @{} # Key: Project name, Value: Absolute path to .vcxproj
    $matches = [regex]::Matches($slnxContent, '<Project Path="([^"]+\.vcxproj)"')
    foreach ($m in $matches) {
        $relPath = $m.Groups[1].Value.Replace('/', '\')
        $name = [System.IO.Path]::GetFileNameWithoutExtension($relPath)
        $projectMap[$name] = Join-Path $workspaceRoot $relPath
    }

    # 2. Collect Git status if needed
    $gitModified = @{}
    $gitUntracked = @{}
    if ($GitFilter -ne 'all') {
        $gitStatus = git -C $workspaceRoot status --porcelain
        if ($null -ne $gitStatus) {
            foreach ($line in $gitStatus) {
                if ($line.Length -lt 4) { continue }
                $status = $line.Substring(0, 2)
                $file = $line.Substring(3).Trim('"').Replace('/', '\')
                $absPath = Join-Path $workspaceRoot $file
                if ($status -match '^(\?\?)') {
                    $gitUntracked[$absPath] = $true
                } elseif ($status -match '^( M|M |A |A|AM|MM)') {
                    $gitModified[$absPath] = $true
                }
            }
        }
    }

    function Test-GitFilter {
        param([string]$path)
        if ($GitFilter -eq 'all') { return $true }
        if ($GitFilter -eq 'modified') { return $gitModified.ContainsKey($path) }
        if ($GitFilter -eq 'untracked') { return $gitUntracked.ContainsKey($path) }
        return $false
    }

    # 3. Collect files for each queried project
    $projectResults = @{}
    
    foreach ($projName in $Projects) {
        if (-not $projectMap.ContainsKey($projName)) {
            Write-Error "Project '$projName' not found in UsagiBuild.slnx."
            continue
        }

        $vcxprojPath = $projectMap[$projName]
        if (-not (Test-Path $vcxprojPath)) {
            Write-Error "Project file not found: $vcxprojPath"
            continue
        }

        $projDir = Split-Path $vcxprojPath -Parent
        
        $allHppCpp = @()
        $projectHppCpp = @()

        if ($SourceFilter -eq 'all' -or $SourceFilter -eq 'excluded') {
            $allHppCpp = Get-ChildItem -Path $projDir -File -Recurse | 
                Where-Object { $_.Extension -match '^\.(hpp|cpp|hxx|cxx|h|c)$' } | 
                Select-Object -ExpandProperty FullName
        }

        if ($SourceFilter -eq 'project' -or $SourceFilter -eq 'excluded') {
            try {
                $xml = [xml](Get-Content $vcxprojPath)
                $nodes = Select-Xml -Xml $xml -XPath "//*[local-name()='ClInclude' or local-name()='ClCompile']"
                foreach ($node in $nodes) {
                    $incPath = $node.Node.Include
                    if ($incPath) {
                        $absIncPath = [System.IO.Path]::GetFullPath((Join-Path $projDir $incPath))
                        $projectHppCpp += $absIncPath
                    }
                }
            } catch {
                Write-Warning "Failed to parse $vcxprojPath as XML."
            }
        }

        $targetFiles = @()
        if ($SourceFilter -eq 'all') {
            $targetFiles = $allHppCpp
        } elseif ($SourceFilter -eq 'project') {
            $targetFiles = $projectHppCpp
        } elseif ($SourceFilter -eq 'excluded') {
            $projSet = @{}
            foreach ($p in $projectHppCpp) { $projSet[$p] = $true }
            foreach ($f in $allHppCpp) {
                if (-not $projSet.ContainsKey($f)) {
                    $targetFiles += $f
                }
            }
        }

        # Apply FileFilter and GitFilter
        $filteredFiles = @()
        foreach ($f in $targetFiles) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            if ($FileFilter -eq 'hpp' -and $ext -notmatch '^\.(hpp|hxx|h)$') { continue }
            if ($FileFilter -eq 'cpp' -and $ext -notmatch '^\.(cpp|cxx|c)$') { continue }
            
            if (Test-GitFilter $f) {
                $filteredFiles += $f
            }
        }

        $projectResults[$projName] = @{
            VcxprojPath = $vcxprojPath
            ProjDir = $projDir
            Files = $filteredFiles | Select-Object -Unique
        }
    }

    # 4. Parse piped content and merge
    $mergedTasks = @{} # Key: AbsPath, Value: TaskItem
    $otherTasks = @()  # Tasks that couldn't be resolved or don't match

    if ($MergeEntries -and $pipedLines.Count -gt 0) {
        $currentTask = $null
        foreach ($line in $pipedLines) {
            if ($line -match '^\s*-\s*\[([ xX])\]\s*(.+)$') {
                $isChecked = ($matches[1].Value.ToLower() -eq 'x')
                $pathRaw = $matches[2].Value.Trim()
                
                $resolvedPath = $null
                # First attempt direct resolution
                if (Test-Path $pathRaw) {
                    $resolvedPath = [System.IO.Path]::GetFullPath($pathRaw)
                } else {
                    $fileName = Split-Path $pathRaw -Leaf
                    if ($fileName) {
                        # Make path comparable easily
                        $comparePath = $pathRaw.Replace('/', '\')
                        
                        try {
                            $searchQuery = """" + $workspaceRoot + """ """ + $fileName + """"
                            $searchResults = Search-Everything $searchQuery -ErrorAction Stop | 
                                             Where-Object { $_.FullName.EndsWith($comparePath, [StringComparison]::OrdinalIgnoreCase) }
                            if ($searchResults -and $searchResults.Count -gt 0) {
                                $resolvedPath = $searchResults[0].FullName
                            }
                        } catch {
                            # Fallback if Everything fails/is not installed
                            $fallbackPaths = Get-ChildItem -Path $workspaceRoot -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue | 
                                             Where-Object { $_.FullName.EndsWith($comparePath, [StringComparison]::OrdinalIgnoreCase) }
                            if ($fallbackPaths) {
                                $resolvedPath = $fallbackPaths[0].FullName
                            }
                        }
                    }
                }

                $taskItem = [pscustomobject]@{
                    AbsPath = $resolvedPath
                    OriginalRelPath = $pathRaw
                    IsChecked = $isChecked
                    Subtasks = [System.Collections.Generic.List[string]]::new()
                    SourceProject = ''
                }

                if ($resolvedPath) {
                    $mergedTasks[$resolvedPath] = $taskItem
                } else {
                    $otherTasks += $taskItem
                }
                $currentTask = $taskItem
            } elseif ($currentTask -and $line -match '^\s\s+-\s*\[([ xX])\]') {
                $currentTask.Subtasks.Add($line.TrimEnd())
            }
        }
    }

    # 5. Integrate new files
    foreach ($projName in $projectResults.Keys) {
        $files = $projectResults[$projName].Files
        $projDir = $projectResults[$projName].ProjDir
        foreach ($f in $files) {
            if (-not $mergedTasks.ContainsKey($f)) {
                $relPath = $f.Substring($projDir.Length).TrimStart('\')
                $mergedTasks[$f] = [pscustomobject]@{
                    AbsPath = $f
                    OriginalRelPath = $relPath
                    IsChecked = $false
                    Subtasks = [System.Collections.Generic.List[string]]::new()
                    SourceProject = $projName
                }
            } else {
                $mergedTasks[$f].SourceProject = $projName
                # Preserve the original rel path if we mapped an existing task to a project
                # But to make it clean under the project header, we update OriginalRelPath
                $relPath = $f.Substring($projDir.Length).TrimStart('\')
                $mergedTasks[$f].OriginalRelPath = $relPath
            }
        }
    }

    # Attempt to assign piped tasks that weren't caught by the script's specific filters
    foreach ($k in @($mergedTasks.Keys)) {
        $task = $mergedTasks[$k]
        if (-not $task.SourceProject) {
            foreach ($projName in $projectResults.Keys) {
                $projDir = $projectResults[$projName].ProjDir
                if ($task.AbsPath.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) {
                    $task.SourceProject = $projName
                    $task.OriginalRelPath = $task.AbsPath.Substring($projDir.Length).TrimStart('\')
                    break
                }
            }
        }
    }

    # 6. Group and Sort
    function Get-Progress($task) {
        $total = 1 + $task.Subtasks.Count
        $ticked = 0
        if ($task.IsChecked) { $ticked++ }
        foreach ($st in $task.Subtasks) {
            if ($st -match '^\s*-\s*\[[xX]\]') { $ticked++ }
        }
        return $ticked / $total
    }

    $finalOutput = [System.Text.StringBuilder]::new()

    foreach ($projName in $Projects) {
        $projTasks = $mergedTasks.Values | Where-Object { $_.SourceProject -eq $projName }
        
        if ($projTasks.Count -gt 0 -or $projectResults[$projName].Files.Count -gt 0) {
            $vcxprojPath = $projectMap[$projName]
            if ($vcxprojPath) {
                $headerPath = $vcxprojPath.Substring($workspaceRoot.Length).TrimStart('\').Replace('\', '/')
                [void]$finalOutput.AppendLine("$headerPath`:")
                [void]$finalOutput.AppendLine()
            }

            $sortedTasks = $projTasks | Sort-Object @(
                @{Expression={Get-Progress $_}; Ascending=$true},
                @{Expression={$_.OriginalRelPath}; Ascending=$true}
            )

            foreach ($task in $sortedTasks) {
                $check = if ($task.IsChecked) { "x" } else { " " }
                $line = "- [$check] $($task.OriginalRelPath)"
                [void]$finalOutput.AppendLine($line)
                foreach ($st in $task.Subtasks) {
                    $stClean = $st -replace '^\s+', ''
                    [void]$finalOutput.AppendLine("  $stClean")
                }
            }
            [void]$finalOutput.AppendLine()
        }
    }

    # Unassigned
    $otherGroup = [System.Collections.Generic.List[psobject]]::new()
    foreach ($t in $otherTasks) { $otherGroup.Add($t) }
    foreach ($t in ($mergedTasks.Values | Where-Object { $_.SourceProject -eq '' })) { $otherGroup.Add($t) }

    if ($otherGroup.Count -gt 0) {
        [void]$finalOutput.AppendLine("Other files:")
        [void]$finalOutput.AppendLine()
        
        $sortedOther = $otherGroup | Sort-Object @(
            @{Expression={Get-Progress $_}; Ascending=$true},
            @{Expression={$_.OriginalRelPath}; Ascending=$true}
        )

        foreach ($task in $sortedOther) {
            $check = if ($task.IsChecked) { "x" } else { " " }
            $line = "- [$check] $($task.OriginalRelPath)"
            [void]$finalOutput.AppendLine($line)
            foreach ($st in $task.Subtasks) {
                $stClean = $st -replace '^\s+', ''
                [void]$finalOutput.AppendLine("  $stClean")
            }
        }
        [void]$finalOutput.AppendLine()
    }

    $outputText = $finalOutput.ToString().TrimEnd()
    
    if ($CopyToClipboard) {
        Set-Clipboard -Value $outputText
        Write-Host "Output copied to clipboard." -ForegroundColor Green
    }

    $outputText
}