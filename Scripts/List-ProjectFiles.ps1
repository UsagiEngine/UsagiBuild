<#
.SYNOPSIS
Lists files from specific projects in the UsagiBuild workspace, with advanced filtering and task merging.

.DESCRIPTION
This script parses UsagiBuild.slnx using an XML parser to resolve project names to their .vcxproj files,
filters their source files based on source, extension, and git status, and outputs
a markdown checklist grouped by project.
It supports pipeline input of existing markdown checklist items and merges them gracefully.

.PARAMETER Projects
An array of project names (without the .vcxproj extension) to query. Can be passed positionally.

.PARAMETER SlnxFilePath
Path to the .slnx solution file. Defaults to '..\UsagiBuild.slnx' relative to the script directory.

.PARAMETER SourceFilter
Filters which files to consider:
- 'project': (Default) Only files explicitly included in the .vcxproj (ClCompile/ClInclude).
- 'all': All C/C++ source and header files under the project's directory.
- 'excluded': Files in the directory but NOT in the .vcxproj.

.PARAMETER FileFilter
Filters by file extension ('hpp', 'cpp', or 'all'). Exhaustive extensions are considered.

.PARAMETER GitFilter
An array of git status filters. Combinable: 'all', 'modified' (unstaged changes), 'staged', 'untracked'.

.PARAMETER Clip
If switched, the script acts as if Get-Clipboard was piped into it, and automatically pipes its output back to Set-Clipboard.

.PARAMETER InputOnly
If switched, the script skips directory scanning and just prints the piped items grouped.

.PARAMETER InputObject
Pipeline input containing markdown checklist text. Used to merge existing checked tasks and subtasks.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$Projects,

    [Parameter(Mandatory=$false)]
    [string]$SlnxFilePath = '..\UsagiBuild.slnx',

    [Parameter(Mandatory=$false)]
    [ValidateSet('all', 'project', 'excluded')]
    [string]$SourceFilter = 'project',

    [Parameter(Mandatory=$false)]
    [ValidateSet('hpp', 'cpp', 'all')]
    [string]$FileFilter = 'all',

    [Parameter(Mandatory=$false)]
    [ValidateSet('all', 'modified', 'untracked', 'staged')]
    [string[]]$GitFilter = @('all'),

    [Parameter(Mandatory=$false)]
    [switch]$Clip,

    [Parameter(Mandatory=$false)]
    [switch]$InputOnly,

    [Parameter(ValueFromPipeline=$true)]
    [string]$InputObject
)

begin {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = $PWD.Path }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
    $resolvedSlnxPath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $SlnxFilePath))

    $pipedLines = [System.Collections.Generic.List[string]]::new()

    if ($Clip) {
        $clipboardText = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($clipboardText)) {
            foreach ($line in $clipboardText -split '\r?\n') {
                $pipedLines.Add($line)
            }
        }
    }

    Import-Module PSEverything -ErrorAction SilentlyContinue

    if ($InputOnly) {
        $filterParams = @('SourceFilter', 'FileFilter', 'GitFilter')
        $overridden = $false
        foreach ($p in $filterParams) {
            if ($PSBoundParameters.ContainsKey($p)) { $overridden = $true }
        }
        if ($overridden) {
            Write-Host "Shio: Warning: -InputOnly overrides filter parameters (-SourceFilter, -FileFilter, -GitFilter)." -ForegroundColor Yellow
        }
    }
}

process {
    if ($null -ne $InputObject) {
        foreach ($line in $InputObject -split '\r?\n') {
            $pipedLines.Add($line)
        }
    }
}

end {
    $cppExts = @('c', 'cpp', 'cxx', 'cc')
    $hppExts = @('h', 'hpp', 'hxx', 'hh', 'inl', 'ipp')
    $allExts = $cppExts + $hppExts

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

    function Test-FileExtension {
        param([string]$Path, [string]$FilterType)
        $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLower()
        if ($FilterType -eq 'hpp') { return $ext -in $hppExts }
        if ($FilterType -eq 'cpp') { return $ext -in $cppExts }
        return $ext -in $allExts
    }

    function Get-SlnxProjects {
        param([string]$SlnxPath)

        $map = @{}
        if (-not (Test-Path $SlnxPath)) {
            Write-Host "Shio: Cannot find UsagiBuild.slnx at $SlnxPath" -ForegroundColor Red
            return $map
        }

        try {
            [xml]$slnxXml = Get-Content $SlnxPath -Raw
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

            $indexStatus = $line[0]
            $treeStatus  = $line[1]
            $filePathRaw = $line.Substring(3)

            if ($filePathRaw -match ' -> ') {
                $filePathRaw = ($filePathRaw -split ' -> ')[-1]
            }
            $filePathRaw = $filePathRaw.Trim('"')
            $filePath = $filePathRaw.Replace('/', '\')

            $absPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $filePath))

            $isUntracked = ($indexStatus -eq '?' -and $treeStatus -eq '?')
            $isStaged = ($indexStatus -ne ' ' -and $indexStatus -ne '?')
            $isModified = ($treeStatus -ne ' ' -and $treeStatus -ne '?')

            $gitMap[$absPath] = @{
                Untracked = $isUntracked
                Staged    = $isStaged
                Modified  = $isModified
            }
        }
        return $gitMap
    }

    function Test-GitStatus {
        param([string]$Path, [hashtable]$GitMap)

        if ('all' -in $GitFilter) { return $true }

        $state = $GitMap[$Path]
        if ($null -eq $state) { return $false }

        if ('untracked' -in $GitFilter -and $state.Untracked) { return $true }
        if ('staged' -in $GitFilter -and $state.Staged) { return $true }
        if ('modified' -in $GitFilter -and $state.Modified) { return $true }

        return $false
    }

    function Get-AllDirectoryFiles {
        param([string]$Directory)
        if (Test-Path $Directory) {
            return @(Get-ChildItem -Path $Directory -File -Recurse |
                Where-Object { Test-FileExtension $_.FullName $FileFilter } |
                Select-Object -ExpandProperty FullName)
        }
        return @()
    }

    function Get-VcxprojFiles {
        param([string]$VcxprojPath, [string]$ProjectDir)

        $includedFiles = @()
        try {
            [xml]$xml = Get-Content $VcxprojPath
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

        $targetFiles = @()
        if (-not $InputOnly) {
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
        }

        $gitMap = Get-GitStatusMapForDir -TargetDir $projDir
        $filteredFiles = @()
        foreach ($f in $targetFiles) {
            if (Test-GitStatus $f $gitMap) {
                $filteredFiles += $f
            }
        }

        return @{
            Name        = $ProjectName
            VcxprojPath = $vcxprojPath
            ProjDir     = $projDir
            Files       = $filteredFiles | Select-Object -Unique
        }
    }

    function Normalize-Path {
        param([string]$Path)
        return [System.IO.Path]::GetFullPath($Path).Replace('/', '\')
    }

    function Parse-PipelineTasks {
        param([hashtable]$ProjectMap)

        $pipedTasks = [System.Collections.Generic.List[psobject]]::new()
        $otherHeaderTasks = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[psobject]]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($pipedLines.Count -eq 0) {
            return @{ Tasks = $pipedTasks; Headers = $otherHeaderTasks }
        }

        $currentTask = $null
        $currentContextHeader = ''
        $currentContextProjectName = ''
        $currentContextProjectDir = ''

        foreach ($line in $pipedLines) {
            if ($line -match '^([a-zA-Z0-9_\-\./\\]+\.vcxproj):$') {
                $currentContextHeader = $Matches[1].Replace('\', '/')
                $currentContextProjectName = [System.IO.Path]::GetFileNameWithoutExtension($currentContextHeader)
                if ($ProjectMap.ContainsKey($currentContextProjectName)) {
                    $currentContextProjectDir = Normalize-Path (Split-Path $ProjectMap[$currentContextProjectName] -Parent)
                } else {
                    $currentContextProjectDir = ''
                }
                continue
            }
            elseif ($line -match '^([^:]+):$') {
                $currentContextHeader = $Matches[1].Trim()
                $currentContextProjectName = ''
                $currentContextProjectDir = ''
                continue
            }

            if ($line -match '^[-*]\s*\[([ xX])\]\s*(.+)$') {
                $isChecked = ($Matches[1].ToLower() -eq 'x')
                $pathRaw = $Matches[2].Trim()

                $resolvedPath = $null
                $resolutionFailed = $false

                if ($currentContextProjectDir) {
                    $parts = $pathRaw.Split('\/')
                    $found = $false
                    for ($i = 0; $i -lt $parts.Length; $i++) {
                        $testSubPath = ($parts[$i..($parts.Length-1)]) -join '\'
                        $testAbsPath = Normalize-Path (Join-Path $currentContextProjectDir $testSubPath)
                        if (Test-Path $testAbsPath) {
                            $resolvedPath = $testAbsPath
                            $pathRaw = $testSubPath
                            $found = $true
                            break
                        }
                    }
                    if (-not $found) {
                        $resolutionFailed = $true
                    }
                }
                else {
                    if (Test-Path $pathRaw) {
                        $resolvedPath = Normalize-Path $pathRaw
                    }
                    else {
                        $fileName = Split-Path $pathRaw -Leaf
                        if ($fileName) {
                            $comparePath = $pathRaw.Replace('/', '\')

                            try {
                                $searchQuery = '"' + $workspaceRoot + '" "' + $fileName + '"'
                                $searchResults = @(Search-Everything $searchQuery -ErrorAction Stop |
                                    Where-Object { $_.FullName.EndsWith($comparePath, [StringComparison]::OrdinalIgnoreCase) })

                                if ($searchResults.Count -gt 0) {
                                    $resolvedPath = $searchResults[0].FullName
                                } else {
                                    throw "Not found via Everything"
                                }
                            }
                            catch {
                                # OMIT Get-ChildItem -Recurse here to vastly improve performance!
                            }

                            if ($resolvedPath) {
                                $resolvedPath = Normalize-Path $resolvedPath
                            }
                        }
                    }
                }

                $taskItem = [pscustomobject]@{
                    AbsPath         = $resolvedPath
                    OriginalRelPath = $pathRaw
                    IsChecked       = $isChecked
                    Subtasks        = [System.Collections.Generic.List[string]]::new()
                    SourceProject   = $currentContextProjectName
                    SourceHeader    = $currentContextHeader
                    IsAssigned      = ($currentContextProjectName -ne '')
                }

                if ($resolutionFailed) {
                    $taskItem.Subtasks.Add("  - [ ] (path cannot be resolved)")
                }

                $pipedTasks.Add($taskItem)

                $headerKey = if ($currentContextHeader) { $currentContextHeader } else { 'Other files and tasks' }
                if (-not $otherHeaderTasks.ContainsKey($headerKey)) {
                    $otherHeaderTasks[$headerKey] = [System.Collections.Generic.List[psobject]]::new()
                }
                $otherHeaderTasks[$headerKey].Add($taskItem)

                $currentTask = $taskItem

            }
            elseif ($currentTask -and $line -match '^\s\s+[-*]\s*\[([ xX])\]') {
                $currentTask.Subtasks.Add($line.TrimEnd())
            }
        }

        return @{ Tasks = $pipedTasks; Headers = $otherHeaderTasks }
    }

    function Get-Progress($Task) {
        $total = 1 + $Task.Subtasks.Count
        $ticked = 0
        if ($Task.IsChecked) { $ticked++ }
        foreach ($st in $Task.Subtasks) {
            if ($st -match '^\s*[-*]\s*\[[xX]\]') { $ticked++ }
        }
        return $ticked / $total
    }

    function Format-TaskList {
        param([array]$Tasks, [System.Text.StringBuilder]$Builder)

        $sortedTasks = $Tasks | Sort-Object @(
            @{Expression= { $_.Subtasks -contains "  - [ ] (path cannot be resolved)" }; Ascending=$true },
            @{Expression= { Get-Progress $_ }; Ascending=$false },
            @{Expression= { $_.OriginalRelPath }; Ascending=$true }
        )

        foreach ($task in $sortedTasks) {
            $check = if ($task.IsChecked) { 'x' } else { ' ' }
            $line = "- [$check] $($task.OriginalRelPath)"
            [void]$Builder.AppendLine($line)
            foreach ($st in $task.Subtasks) {
                $stClean = $st -replace '^\s*[-*]\s*\[', '  - ['
                [void]$Builder.AppendLine($stClean)
            }
        }
    }

    # --- MAIN EXECUTION FLOW ---

    $projectMap = Get-SlnxProjects -SlnxPath $resolvedSlnxPath

    $projectResults = @{}
    if (-not $InputOnly) {
        foreach ($projName in $Projects) {
            $res = Get-ProjectSourceFiles -ProjectName $projName -ProjectMap $projectMap
            if ($res.Count -gt 0) {
                $projectResults[$projName] = $res
            }
        }
    } else {
        foreach ($projName in $Projects) {
            if ($projectMap.ContainsKey($projName)) {
                $vcxprojPath = $projectMap[$projName]
                $projDir = Split-Path $vcxprojPath -Parent
                $projectResults[$projName] = @{
                    Name        = $projName
                    VcxprojPath = $vcxprojPath
                    ProjDir     = $projDir
                    Files       = @()
                }
            }
        }
    }

    $pipedData = Parse-PipelineTasks -ProjectMap $projectMap
    $pipedTasks = $pipedData.Tasks
    $otherHeaderTasks = $pipedData.Headers

    $mergedTasks = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($pt in $pipedTasks) {
        if ($pt.AbsPath) {
            $mergedTasks[$pt.AbsPath] = $pt
        }
    }

    if (-not $InputOnly) {
        foreach ($projName in $projectResults.Keys) {
            $files = $projectResults[$projName].Files
            $projDir = $projectResults[$projName].ProjDir

            foreach ($f in $files) {
                $fKey = Normalize-Path $f

                if ($mergedTasks.ContainsKey($fKey)) {
                    $matchedPipedTask = $mergedTasks[$fKey]
                    $matchedPipedTask.IsAssigned = $true
                    $matchedPipedTask.SourceProject = $projName
                    $matchedPipedTask.OriginalRelPath = $f.Substring($projDir.Length).TrimStart('\')
                } else {
                    $matchedPipedTask = $null
                    foreach ($pt in $pipedTasks) {
                        if (-not $pt.AbsPath) {
                            $comparePath = $pt.OriginalRelPath.Replace('/', '\')
                            if ($fKey.EndsWith($comparePath, [StringComparison]::OrdinalIgnoreCase)) {
                                $matchedPipedTask = $pt
                                break
                            }
                        }
                    }

                    if ($null -ne $matchedPipedTask) {
                        $matchedPipedTask.AbsPath = $fKey
                        $matchedPipedTask.IsAssigned = $true
                        $matchedPipedTask.SourceProject = $projName
                        $matchedPipedTask.OriginalRelPath = $f.Substring($projDir.Length).TrimStart('\')
                        $mergedTasks[$fKey] = $matchedPipedTask
                    }
                    else {
                        $relPath = $f.Substring($projDir.Length).TrimStart('\')
                        $mergedTasks[$fKey] = [pscustomobject]@{
                            AbsPath         = $fKey
                            OriginalRelPath = $relPath
                            IsChecked       = $false
                            Subtasks        = [System.Collections.Generic.List[string]]::new()
                            SourceProject   = $projName
                            SourceHeader    = ''
                            IsAssigned      = $true
                        }
                    }
                }
            }
        }
    }

    $finalOutput = [System.Text.StringBuilder]::new()
    $headersToPrint = @{}

    foreach ($header in $otherHeaderTasks.Keys) {
        if ($header -ne 'Other files and tasks') {
            $headersToPrint[$header] = [System.Collections.Generic.List[psobject]]::new()
            foreach ($t in $otherHeaderTasks[$header]) {
                $headersToPrint[$header].Add($t)
            }
        }
    }

    foreach ($projName in $Projects) {
        $projTasks = @($mergedTasks.Values | Where-Object { $_.SourceProject -eq $projName })
        if ($projTasks.Count -gt 0 -or ($projectResults.ContainsKey($projName) -and $projectResults[$projName].Files.Count -gt 0)) {
            $vcxprojPath = $projectMap[$projName]
            if ($vcxprojPath) {
                $headerPath = $vcxprojPath.Substring($workspaceRoot.Length).TrimStart('\').Replace('\', '/')
                if (-not $headersToPrint.ContainsKey($headerPath)) {
                    $headersToPrint[$headerPath] = [System.Collections.Generic.List[psobject]]::new()
                }
                foreach ($t in $projTasks) {
                    if (-not $headersToPrint[$headerPath].Contains($t)) {
                        $headersToPrint[$headerPath].Add($t)
                    }
                }
            }
        }
    }

    $sortedHeaders = $headersToPrint.Keys | Sort-Object @(
        @{Expression= {
            $h = $_
            $isQueried = $false
            foreach ($p in $Projects) {
                $pattern = $p + "\.vcxproj"
                if ($h -match $pattern) { $isQueried = $true; break }
            }
            if ($isQueried) { 0 } else { 1 }
        }; Ascending=$true},
        @{Expression= { $_ }; Ascending=$true}
    )

    foreach ($header in $sortedHeaders) {
        $list = $headersToPrint[$header]
        if ($list.Count -gt 0) {
            [void]$finalOutput.AppendLine("$header`:")
            [void]$finalOutput.AppendLine()
            Format-TaskList -Tasks $list -Builder $finalOutput
            [void]$finalOutput.AppendLine()
        }
    }

    $otherGroup = [System.Collections.Generic.List[psobject]]::new()

    if ($otherHeaderTasks.ContainsKey('Other files and tasks')) {
        foreach ($t in $otherHeaderTasks['Other files and tasks']) {
            if (-not $t.IsAssigned -and $t.SourceHeader -eq '') {
                $otherGroup.Add($t)
            }
        }
    }

    foreach ($t in $mergedTasks.Values) {
        if (-not $t.SourceProject -and -not $otherGroup.Contains($t) -and -not $t.SourceHeader) {
            $otherGroup.Add($t)
        }
    }

    if ($otherGroup.Count -gt 0) {
        [void]$finalOutput.AppendLine('Other files and tasks:')
        [void]$finalOutput.AppendLine()
        Format-TaskList -Tasks $otherGroup -Builder $finalOutput
        [void]$finalOutput.AppendLine()
    }

    $outputText = $finalOutput.ToString().TrimEnd()

    if ($Clip) {
        Write-Host $outputText
        Set-Clipboard -Value $outputText
        Write-Host "Shio: Output was piped back to your clipboard." -ForegroundColor Green
    }
    else {
        $outputText
    }
}
