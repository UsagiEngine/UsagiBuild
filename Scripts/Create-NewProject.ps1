<#
.SYNOPSIS
  Creates a new MSBuild project from a template.
.DESCRIPTION
  This script automates the creation of a new C++ project based on a template.
  It copies the template files, renames them, updates project-specific values
  (like the GUID and project name), and optionally adds the new project to a
  Visual Studio solution file.
.PARAMETER TemplateFolder
  The path to the directory containing template folders. Defaults to '../Templates/'
  relative to the script's location.
.PARAMETER TemplateName
  The name of the template to use. This corresponds to a subfolder within the
  TemplateFolder. Defaults to 'UsagiClang'.
.PARAMETER ProjectType
  The type of project to create. Accepts any case-insensitive, unambiguous prefix
  of 'StaticLibrary' or 'Application'.
.PARAMETER ProjectName
  The name for the new project. This name will be used for the folder, the
  .vcxproj file, and the RootNamespace inside the project file.
.PARAMETER TargetSolution
  The path to the solution file (.sln or .slnx) to which the new project should
  be added. If not provided, the script will search for one in the current
  directory. A warning will be issued if no solution is found.
.PARAMETER TargetFolder
  The parent directory where the new project folder will be created.
.PARAMETER DryRun
  If specified, the script will log all the actions it would take without
  actually modifying any files or directories.
.EXAMPLE
  .\Create-NewProject.ps1 -ProjectType App -ProjectName "MyNewApp" -TargetFolder "D:\dev\Projects"
  This command creates a new application project in 'D:\dev\Projects\MyNewApp'.
.EXAMPLE
  .\Create-NewProject.ps1 -ProjectType static -ProjectName "MyCoolLib" -TargetFolder "Libs" -TargetSolution "MySolution.slnx"
  This command creates a new static library named 'MyCoolLib' in the 'Libs' subfolder
  and adds it to 'MySolution.slnx'.
#>
[CmdletBinding()]
param(
  [string]$TemplateFolder = (Join-Path -Path $PSScriptRoot -ChildPath '../Templates/'),
  [string]$TemplateName = 'UsagiClang',

  [Parameter(Mandatory = $true)]
  [string]$ProjectType,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-zA-Z0-9_.-]+$')]
  [string]$ProjectName,

  [string]$TargetSolution,

  [Parameter(Mandatory = $true)]
  [string]$TargetFolder,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Write-Host "Starting project creation process."
if ($DryRun) {
  Write-Warning "DRY RUN ENABLED. No changes will be made to the filesystem."
}

# --- Argument Validation and Path Resolution ---

Write-Host "Step 1: Validating arguments and resolving paths..."

# Validate ProjectType with prefix matching
$validProjectTypes = @('StaticLibrary', 'Application')
$matchedTypes = $validProjectTypes | Where-Object { $_.StartsWith($ProjectType, [System.StringComparison]::InvariantCultureIgnoreCase) }
if ($matchedTypes.Count -eq 0) {
    throw "Invalid ProjectType '$ProjectType'. No match found. Valid types are: $($validProjectTypes -join ', ')"
}
if ($matchedTypes.Count -gt 1) {
    throw "Ambiguous ProjectType '$ProjectType'. It matches: $($matchedTypes -join ', '). Please be more specific."
}
$ConfigurationType = $matchedTypes #[0] # Use the canonical name # `[0]` causes the `ConfigurationType` only have the first character.
Write-Host "  [INFO] Matched project type: $ConfigurationType"

# Resolve and validate TemplateFolder
$TemplateFolder = (Resolve-Path -Path $TemplateFolder).Path
$FullTemplatePath = Join-Path -Path $TemplateFolder -ChildPath $TemplateName
if (-not (Test-Path -Path $FullTemplatePath -PathType Container)) {
  throw "Template folder not found at '$FullTemplatePath'."
}
Write-Host "  [OK] Template folder found: $FullTemplatePath"

# Resolve and validate TargetFolder (which is the parent)
# Shio: Create the directory if it doesn't exist.
if (-not (Test-Path -Path $TargetFolder)) {
    Write-Host "  [INFO] Target folder (parent) '$TargetFolder' does not exist. Creating it."
    if (-not $DryRun) {
        New-Item -Path $TargetFolder -ItemType Directory | Out-Null
    }
}

$ParentFolder = (Resolve-Path -Path $TargetFolder).Path
if (-not (Test-Path -Path $ParentFolder -PathType Container)) {
    throw "Target folder (parent) '$ParentFolder' exists but is not a directory."
}
Write-Host "  [OK] Target parent folder is ready: $ParentFolder"

# Define the final project path and validate it
$ProjectDestinationPath = Join-Path -Path $ParentFolder -ChildPath $ProjectName
if (Test-Path -Path $ProjectDestinationPath) {
    if (-not (Get-Item -Path $ProjectDestinationPath).PSIsContainer) {
        throw "A file with the name '$ProjectName' already exists in the target folder."
    }
    if (Get-ChildItem -Path $ProjectDestinationPath) {
        throw "Project folder '$ProjectDestinationPath' already exists and is not empty."
    }
    Write-Host "  [INFO] Project folder already exists and is empty. It will be used."

    $existingFolderName = (Get-Item -Path $ProjectDestinationPath).Name
    if ($existingFolderName -cne $ProjectName) {
        Write-Host "  Renaming existing folder from '$existingFolderName' to '$ProjectName' to match case."
        if (-not $DryRun) {
            Rename-Item -Path $ProjectDestinationPath -NewName $ProjectName
            $ProjectDestinationPath = Join-Path -Path $ParentFolder -ChildPath $ProjectName
        }
    }
}
Write-Host "  [OK] Project destination path is valid: $ProjectDestinationPath"


# Find and validate TargetSolution
if (-not ([string]::IsNullOrEmpty($TargetSolution))) {
  $TargetSolution = (Resolve-Path -Path (Join-Path -Path $PWD -ChildPath $TargetSolution)).Path
  if (-not (Test-Path -Path $TargetSolution -PathType Leaf)) {
    throw "Specified solution file not found at '$TargetSolution'."
  }
}
else {
  $TargetSolution = & "$PSScriptRoot\Find-SolutionFile.ps1" -Directory $PWD
}

Write-Host "Argument validation complete."

# --- Template File Validation ---

Write-Host "Step 2: Validating template files..."
$TemplateVcxproj = Join-Path -Path $FullTemplatePath -ChildPath "$TemplateName.vcxproj"
$TemplateFilters = Join-Path -Path $FullTemplatePath -ChildPath "$TemplateName.vcxproj.filters"

if (-not (Test-Path -Path $TemplateVcxproj -PathType Leaf)) {
  throw "Template file not found: $TemplateVcxproj"
}
if (-not (Test-Path -Path $TemplateFilters -PathType Leaf)) {
  throw "Template file not found: $TemplateFilters"
}
Write-Host "  [OK] All required template files are present."

# --- Project Creation and File Copy ---

Write-Host "Step 3: Creating project structure and copying files..."
$DestVcxproj = Join-Path $ProjectDestinationPath "$ProjectName.vcxproj"
$DestFilters = Join-Path $ProjectDestinationPath "$ProjectName.vcxproj.filters"

if (-not $DryRun) {
  if (-not (Test-Path -Path $ProjectDestinationPath)) {
    Write-Host "  Creating directory: $ProjectDestinationPath"
    New-Item -Path $ProjectDestinationPath -ItemType Directory | Out-Null
  }
  Copy-Item -Path $TemplateVcxproj -Destination $DestVcxproj
  Copy-Item -Path $TemplateFilters -Destination $DestFilters
}
Write-Host "  Copied '$TemplateVcxproj' to '$DestVcxproj'."
Write-Host "  Copied '$TemplateFilters' to '$DestFilters'."

# --- File Content Modification ---

Write-Host "Step 4: Modifying project file content..."
$NewGuid = ([guid]::NewGuid()).ToString('B').ToLower()

Write-Host "  New Project GUID: $NewGuid"
Write-Host "  New RootNamespace: $ProjectName"
Write-Host "  New ConfigurationType: $ConfigurationType"

if (-not $DryRun) {
  $vcxprojContent = Get-Content -Path $DestVcxproj -Raw
  $vcxprojContent = $vcxprojContent -replace '(<ProjectGuid>)(.*)(<\/ProjectGuid>)', "`$1$NewGuid`$3"
  $vcxprojContent = $vcxprojContent -replace '(<RootNamespace>)(.*)(<\/RootNamespace>)', "`$1$ProjectName`$3"
  $vcxprojContent = $vcxprojContent -replace '(<ConfigurationType>)(.*)(<\/ConfigurationType>)', "`$1$ConfigurationType`$3"
  Set-Content -Path $DestVcxproj -Value $vcxprojContent
}
Write-Host "  [OK] Successfully updated '$DestVcxproj' with new project details."

# --- Solution Integration ---

if ($TargetSolution) {
  Write-Host "Step 5: Adding new project to solution..."
  & "$PSScriptRoot\Add-ProjectToSolution.ps1" -SolutionPath $TargetSolution -ProjectPath $DestVcxproj -DryRun:$DryRun
}

Write-Host "Project '$ProjectName' created successfully at '$ProjectDestinationPath'."
