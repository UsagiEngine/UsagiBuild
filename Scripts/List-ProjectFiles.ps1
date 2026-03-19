<#
.SYNOPSIS
Lists files from specific projects in the UsagiBuild workspace, with advanced filtering and task merging.

.DESCRIPTION
This script parses UsagiBuild.slnx using an XML parser to resolve project names to their .vcxproj files,
filters their source files based on source, extension, and git status, and outputs
a markdown checklist grouped by project.
It supports pipeline input of existing markdown checklist items and merges them gracefully.

.PARAMETER Projects
An array of project names (without the .vcxproj extension) to query.

.PARAMETER SourceFilter
Filters which files to consider:
- 'all': All C/C++ source and header files under the project's directory.
- 'project': Only files explicitly included in the .vcxproj (ClCompile/ClInclude).
- 'excluded': Files in the directory but NOT in the .vcxproj.

.PARAMETER FileFilter
Filters by file extension ('hpp', 'cpp', or 'all'). Exhaustive extensions are considered.

.PARAMETER GitFilter
An array of git status filters. Combinable: 'all', 'modified' (unstaged changes), 'staged', 'untracked'.

.PARAMETER InputObject
Pipeline input containing markdown checklist text. Used to merge existing checked tasks and subtasks.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [string[]]$Projects,

    [Parameter(Mandatory=$false)]
    [ValidateSet('all', 'project', 'excluded')]
    [string]$SourceFilter = 'all',

    [Parameter(Mandatory=$false)]
    [ValidateSet('hpp', 'cpp', 'all')]
    [string]$FileFilter = 'all',

    [Parameter(Mandatory=$false)]
    [ValidateSet('all', 'modified', 'untracked', 'staged')]
    [string[]]$GitFilter = @('all'),

    [Parameter(ValueFromPipeline=$true)]
    [string]$InputObject
)

begin {
    # Set up basic variables and import needed modules
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = $PWD.Path }

    # Calculate workspace root as the parent of the script's directory
    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))

    # Store lines from pipeline to process later
    $pipedLines = [System.Collections.Generic.List[string]]::new()

    # Attempt to load PSEverything for blazingly fast file resolution
    Import-Module PSEverything -ErrorAction SilentlyContinue
}

process {
    # Accumulate any piped input line by line
    if ($null -ne $InputObject) {
        foreach ($line in $InputObject -split '\r?\n') {
            $pipedLines.Add($line)
        }
    }
}

end {
    # Define exhaustive lists of C/C++ extensions
    $cppExts = @('c', 'cpp', 'cxx', 'cc')
    $hppExts = @('h', 'hpp', 'hxx', 'hh', 'inl', 'ipp')
    $allExts = $cppExts + $hppExts

    # Helper: Build an Everything extension search query
    function Get-EverythingExtFilter {
        param([string]$FilterType)
        if ($FilterType -eq 'hpp') {
            return 'ext:' + ($hppExts -join ';')
        }
        elseif ($FilterType -eq 'cpp') {
            return 'ext:' + ($cppExts -join ';')
        }
        else {
            return 'ext:' + ($allExts -join ';')
        }
    }

    # Helper: Match an extension using the exhaustive arrays
    function Test-FileExtension {
        param([string]$Path, [string]$FilterType)
        $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLower()
        if ($FilterType -eq 'hpp') { return $ext -in $hppExts }
        if ($FilterType -eq 'cpp') { return $ext -in $cppExts }
        return $ext -in $allExts
    }

    # Helper: Parses UsagiBuild.slnx as XML and builds a map of project names to .vcxproj paths
    function Get-SlnxProjects {
        param([string]$SlnxPath)

        $map = @{}
        if (-not (Test-Path $SlnxPath)) {
            Write-Host "Shio: Cannot find UsagiBuild.slnx at $SlnxPath" -ForegroundColor Red
            return $map
        }

        try {
            # Load the solution as XML
            [xml]$slnxXml = Get-Content $SlnxPath -Raw
            # Find all Project nodes that have a .vcxproj path
            $projectNodes = $slnxXml.SelectNodes("//Project[contains(@Path, '.vcxproj')]")
            foreach ($node in $projectNodes) {
                $relPath = $node.Path.Replace('/', '\')
                $name = [System.IO.Path]::GetFileNameWithoutExtension($relPath)
                $map[$name] = Join-Path $workspaceRoot $relPath
            }
        }
        catch {
            Write-Host "Shio: Failed to parse $SlnxPath as XML. Error: $_" -ForegroundColor Red
        }
        return $map
    }

    $globalGitMapCache = @{}

    # Helper: Runs git status and builds a status dictionary mapping file paths to their git state
    function Get-GitStatusMapForDir {
        param([string]$TargetDir)

        $repoRoot = git -C $TargetDir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) { return @{} }
        $repoRoot = [System.IO.Path]::GetFullPath($repoRoot)

        if ($globalGitMapCache.ContainsKey($repoRoot)) {
            return $globalGitMapCache[$repoRoot]
        }

        $gitMap = @{}
        $globalGitMapCache[$repoRoot] = $gitMap

        $gitStatus = git -C $repoRoot status --porcelain
        if ($null -eq $gitStatus) { return $gitMap }

        foreach ($line in $gitStatus) {
            if ($line.Length -lt 4) { continue }

            # The first two characters represent index and working tree states
            $indexStatus = $line[0]
            $treeStatus  = $line[1]
            $filePathRaw = $line.Substring(3)

            # Handle rename syntax 'R  old -> new'
            if ($filePathRaw -match ' -> ') {
                $filePathRaw = ($filePathRaw -split ' -> ')[-1]
            }
            $filePathRaw = $filePathRaw.Trim('"')
            $filePath = $filePathRaw.Replace('/', '\')
            
            $absPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $filePath))

            $isUntracked = ($indexStatus -eq '?' -and $treeStatus -eq '?')
            # Staged changes have something other than space or '?' in the index
            $isStaged = ($indexStatus -ne ' ' -and $indexStatus -ne '?')
            # Unstaged modified changes have something other than space or '?' in the working tree
            $isModified = ($treeStatus -ne ' ' -and $treeStatus -ne '?')

            $gitMap[$absPath] = @{
                Untracked = $isUntracked
                Staged    = $isStaged
                Modified  = $isModified
            }
        }
        return $gitMap
    }

    # Helper: Determines if a file path passes the active Git filters
    function Test-GitStatus {
        param([string]$Path, [hashtable]$GitMap)

        # 'all' means accept everything regardless of git state
        if ('all' -in $GitFilter) { return $true }

        $state = $GitMap[$Path]
        if ($null -eq $state) { return $false } # Tracked but unmodified

        if ('untracked' -in $GitFilter -and $state.Untracked) { return $true }
        if ('staged' -in $GitFilter -and $state.Staged) { return $true }
        if ('modified' -in $GitFilter -and $state.Modified) { return $true }

        return $false
    }

    # Helper: Gets all matching files in the directory recursively
    function Get-AllDirectoryFiles {
        param([string]$Directory)

        # Standard recursive search natively via powershell (fast enough for single project dirs and more reliable)
        return @(Get-ChildItem -Path $Directory -File -Recurse |
            Where-Object { Test-FileExtension $_.FullName $FileFilter } |
            Select-Object -ExpandProperty FullName)
    }

    # Helper: Parses the .vcxproj to find files explicitly included in the project
    function Get-VcxprojFiles {
        param([string]$VcxprojPath, [string]$ProjectDir)

        $includedFiles = @()
        try {
            [xml]$xml = Get-Content $VcxprojPath
            # Look for ClInclude or ClCompile elements typically used for source code
            $nodes = Select-Xml -Xml $xml -XPath "//*[local-name()='ClInclude' or local-name()='ClCompile']"
            foreach ($node in $nodes) {
                $incPath = $node.Node.Include
                if ($incPath) {
                    $absIncPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $incPath))
                    if (Test-FileExtension $absIncPath $FileFilter) {
                        $includedFiles += $absIncPath
                    }
                }
            }
        }
        catch {
            Write-Host "Shio: Failed to parse $VcxprojPath as XML." -ForegroundColor Yellow
        }
        return $includedFiles
    }

    # Helper: Combines source and git filters for a specific project
    function Get-ProjectSourceFiles {
        param([string]$ProjectName, [hashtable]$ProjectMap)

        if (-not $ProjectMap.ContainsKey($ProjectName)) {
            Write-Host "Shio: Project '$ProjectName' not found in UsagiBuild.slnx." -ForegroundColor Yellow
            return @{}
        }

        $vcxprojPath = $ProjectMap[$ProjectName]
        if (-not (Test-Path $vcxprojPath)) {
            Write-Host "Shio: Project file not found: $vcxprojPath" -ForegroundColor Yellow
            return @{}
        }

        $projDir = Split-Path $vcxprojPath -Parent

        # Decide which base set of files we need based on SourceFilter
        $targetFiles = @()
        if ($SourceFilter -eq 'all') {
            $targetFiles = Get-AllDirectoryFiles $projDir
        }
        elseif ($SourceFilter -eq 'project') {
            $targetFiles = Get-VcxprojFiles $vcxprojPath $projDir
        }
        elseif ($SourceFilter -eq 'excluded') {
            $allFiles = Get-AllDirectoryFiles $projDir
            $projFiles = Get-VcxprojFiles $vcxprojPath $projDir

            $projSet = @{}
            foreach ($p in $projFiles) { $projSet[$p] = $true }

            foreach ($f in $allFiles) {
                if (-not $projSet.ContainsKey($f)) {
                    $targetFiles += $f
                }
            }
        }

        # Apply Git status filter to the target files
        $gitMap = Get-GitStatusMapForDir -TargetDir $projDir
        $filteredFiles = @()
        foreach ($f in $targetFiles) {
            if (Test-GitStatus $f $gitMap) {
                $filteredFiles += $f
            }
        }

        # Return structured project info mapping
        return @{
            Name        = $ProjectName
            VcxprojPath = $vcxprojPath
            ProjDir     = $projDir
            Files       = $filteredFiles | Select-Object -Unique
        }
    }

    # Helper: Normalizes a path to absolute, lowercased with backslashes
    function Normalize-Path {
        param([string]$Path)
        return [System.IO.Path]::GetFullPath($Path).Replace('/', '\').ToLower()
    }

    # Helper: Parses pipeline markdown checklist into structured task items
    function Parse-PipelineTasks {
        $pipedTasks = [System.Collections.Generic.List[psobject]]::new()

        if ($pipedLines.Count -eq 0) {
            return $pipedTasks
        }

        $currentTask = $null
        foreach ($line in $pipedLines) {
            # Match top-level checklist item: "- [ ] Path/To/File" (no leading spaces)
            if ($line -match '^-\s*\[([ xX])\]\s*(.+)$') {
                $isChecked = ($Matches[1].ToLower() -eq 'x')
                $pathRaw = $Matches[2].Trim()

                # Construct internal task representation
                $taskItem = [pscustomobject]@{
                    OriginalRelPath = $pathRaw
                    IsChecked       = $isChecked
                    Subtasks        = [System.Collections.Generic.List[string]]::new()
                    SourceProject   = ''
                    IsAssigned      = $false
                }

                $pipedTasks.Add($taskItem)
                $currentTask = $taskItem

            }
            elseif ($currentTask -and $line -match '^\s\s+-\s*\[([ xX])\]') {
                # Match subtasks (indented checkboxes) and tie them to the last currentTask
                $currentTask.Subtasks.Add($line.TrimEnd())
            }
        }

        return $pipedTasks
    }

    # Helper: Calculates task completion ratio for sorting items cleanly
    function Get-Progress($Task) {
        $total = 1 + $Task.Subtasks.Count
        $ticked = 0
        if ($Task.IsChecked) { $ticked++ }
        foreach ($st in $Task.Subtasks) {
            if ($st -match '^\s*-\s*\[[xX]\]') { $ticked++ }
        }
        return $ticked / $total
    }

    # Helper: Formats a task list as markdown strings based on completion and path
    function Format-TaskList {
        param([array]$Tasks, [System.Text.StringBuilder]$Builder)

        $sortedTasks = $Tasks | Sort-Object @(
            @{Expression= { Get-Progress $_ }; Ascending=$false },
            @{Expression= { $_.OriginalRelPath }; Ascending=$true }
        )

        foreach ($task in $sortedTasks) {
            $check = if ($task.IsChecked) { 'x' } else { ' ' }
            $line = "- [$check] $($task.OriginalRelPath)"
            [void]$Builder.AppendLine($line)
            foreach ($st in $task.Subtasks) {
                # Ensure exactly 2 spaces indentation for subtasks
                $stClean = $st -replace '^\s+', ''
                [void]$Builder.AppendLine("  $stClean")
            }
        }
    }

    # --- MAIN EXECUTION FLOW ---

    # 1. Parse UsagiBuild.slnx to map project names to paths
    $slnxPath = Join-Path $workspaceRoot 'UsagiBuild.slnx'
    $projectMap = Get-SlnxProjects -SlnxPath $slnxPath

    # 2. Process each requested project to find relevant files
    $projectResults = @{}
    foreach ($projName in $Projects) {
        $res = Get-ProjectSourceFiles -ProjectName $projName -ProjectMap $projectMap
        if ($res.Count -gt 0) {
            $projectResults[$projName] = $res
        }
    }

    # 4. Parse any pipeline input to retrieve existing checklist items
    $pipedTasks = Parse-PipelineTasks
    $mergedTasks = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 5. Integrate newly discovered files with any existing tasks
    foreach ($projName in $projectResults.Keys) {
        $files = $projectResults[$projName].Files
        $projDir = $projectResults[$projName].ProjDir

        foreach ($f in $files) {
            $fKey = Normalize-Path $f
            
            # Try to find a matching piped task
            $matchedPipedTask = $null
            foreach ($pt in $pipedTasks) {
                if (-not $pt.IsAssigned) {
                    $comparePath = $pt.OriginalRelPath.Replace('/', '\')
                    if ($fKey.EndsWith($comparePath, [StringComparison]::OrdinalIgnoreCase)) {
                        $matchedPipedTask = $pt
                        break
                    }
                }
            }

            if ($null -eq $matchedPipedTask) {
                # Create a new unchecked task for this file
                $relPath = $f.Substring($projDir.Length).TrimStart('\')
                $mergedTasks[$fKey] = [pscustomobject]@{
                    AbsPath         = $fKey
                    OriginalRelPath = $relPath
                    IsChecked       = $false
                    Subtasks        = [System.Collections.Generic.List[string]]::new()
                    SourceProject   = $projName
                }
            }
            else {
                # Update existing piped task to associate it with this project header
                $matchedPipedTask.IsAssigned = $true
                $matchedPipedTask.SourceProject = $projName
                
                # Make sure the task takes on the project-relative path cleanly
                $matchedPipedTask.OriginalRelPath = $f.Substring($projDir.Length).TrimStart('\')

                $mergedTasks[$fKey] = $matchedPipedTask
            }
        }
    }

    $otherGroup = [System.Collections.Generic.List[psobject]]::new()
    
    # Process remaining piped tasks that were not matched to any found files
    foreach ($pt in $pipedTasks) {
        if (-not $pt.IsAssigned) {
            $assigned = $false
            foreach ($projName in $projectResults.Keys) {
                $projDir = $projectResults[$projName].ProjDir
                # Test if the user provided an absolute path that belongs to this project
                if ([System.IO.Path]::IsPathRooted($pt.OriginalRelPath)) {
                    $normPtPath = Normalize-Path $pt.OriginalRelPath
                    if ($normPtPath.StartsWith($projDir.ToLower())) {
                        $pt.SourceProject = $projName
                        # Format clearly relative to project
                        $pt.OriginalRelPath = $normPtPath.Substring($projDir.Length).TrimStart('\')
                        $mergedTasks[$normPtPath] = $pt
                        $assigned = $true
                        break
                    }
                }
            }

            if (-not $assigned) {
                $otherGroup.Add($pt)
            }
        }
    }

    # 6. Generate final markdown output
    $finalOutput = [System.Text.StringBuilder]::new()

    foreach ($projName in $Projects) {
        # Group tasks that belong to this project
        $projTasks = $mergedTasks.Values | Where-Object { $_.SourceProject -eq $projName }

        if ($projTasks.Count -gt 0 -or ($projectResults.ContainsKey($projName) -and $projectResults[$projName].Files.Count -gt 0)) {
            $vcxprojPath = $projectMap[$projName]
            if ($vcxprojPath) {
                $headerPath = $vcxprojPath.Substring($workspaceRoot.Length).TrimStart('\').Replace('\', '/')
                [void]$finalOutput.AppendLine("$headerPath`:")
                [void]$finalOutput.AppendLine()
            }

            Format-TaskList -Tasks $projTasks -Builder $finalOutput
            [void]$finalOutput.AppendLine()
        }
    }

    # Format any unassigned/other tasks that couldn't be mapped
    foreach ($t in ($mergedTasks.Values | Where-Object { -not $_.SourceProject })) {
        $otherGroup.Add($t)
    }

    if ($otherGroup.Count -gt 0) {
        [void]$finalOutput.AppendLine('Other files:')
        [void]$finalOutput.AppendLine()
        Format-TaskList -Tasks $otherGroup -Builder $finalOutput
        [void]$finalOutput.AppendLine()
    }

    # Emit the trimmed string to the pipeline (allows natively piping to Set-Clipboard)
    $outputText = $finalOutput.ToString().TrimEnd()
    $outputText
}
