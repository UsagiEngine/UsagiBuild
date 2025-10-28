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
  The type of project to create. Must be either 'StaticLib' or 'App'.
.PARAMETER ProjectName
  The name for the new project. This name will be used for the folder, the
  .vcxproj file, and the RootNamespace inside the project file.
.PARAMETER TargetSolution
  The path to the solution file (.sln or .slnx) to which the new project should
  be added. If not provided, the script will search for one in the current
  directory. A warning will be issued if no solution is found.
.PARAMETER TargetFolder
  The path to the directory where the new project will be created. The directory
  must be empty or not exist.
.PARAMETER DryRun
  If specified, the script will log all the actions it would take without
  actually modifying any files or directories.
.EXAMPLE
  .\Create-NewProject.ps1 -ProjectType App -ProjectName "MyNewApp" -TargetFolder "D:\dev\MyNewApp"
  This command creates a new application project named 'MyNewApp' in the specified
  target folder.
.EXAMPLE
  .\Create-NewProject.ps1 -ProjectType StaticLib -ProjectName "MyCoolLib" -TargetFolder "Libs\MyCoolLib" -TargetSolution "MySolution.slnx"
  This command creates a new static library and adds it to 'MySolution.slnx'.
.EXAMPLE
  .\Create-NewProject.ps1 -ProjectType App -ProjectName "TestApp" -TargetFolder "D:\temp\TestApp" -DryRun
  This command performs a dry run, showing what would happen without creating the
  'TestApp' project.
#>
[CmdletBinding()]
param(
  [string]$TemplateFolder = (Join-Path -Path $PSScriptRoot -ChildPath '../Templates/'),
  [string]$TemplateName = 'UsagiClang',

  [Parameter(Mandatory = $true)]
  [ValidateSet('StaticLib', 'App')]
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

# Resolve and validate TemplateFolder
$TemplateFolder = (Resolve-Path -Path $TemplateFolder).Path
$FullTemplatePath = Join-Path -Path $TemplateFolder -ChildPath $TemplateName
if (-not (Test-Path -Path $FullTemplatePath -PathType Container)) {
  throw "Template folder not found at '$FullTemplatePath'."
}
Write-Host "  [OK] Template folder found: $FullTemplatePath"

# Resolve and validate TargetFolder
if (-not (Test-Path -Path $TargetFolder)) {
    $TargetFolder = (Resolve-Path -Path (Join-Path -Path $PWD -ChildPath $TargetFolder -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue).Path
} else {
    $TargetFolder = (Resolve-Path -Path $TargetFolder).Path
}

if ((Test-Path -Path $TargetFolder) -and (Get-ChildItem -Path $TargetFolder)) {
  throw "Target folder '$TargetFolder' already exists and is not empty."
}
if (-not (Test-Path -Path (Split-Path -Path $TargetFolder -Parent))) {
    throw "Parent directory for target folder '$TargetFolder' does not exist."
}
Write-Host "  [OK] Target folder is valid: $TargetFolder"


# Find and validate TargetSolution
if (-not ([string]::IsNullOrEmpty($TargetSolution))) {
  $TargetSolution = (Resolve-Path -Path (Join-Path -Path $PWD -ChildPath $TargetSolution)).Path
  if (-not (Test-Path -Path $TargetSolution -PathType Leaf)) {
    throw "Specified solution file not found at '$TargetSolution'."
  }
}
else {
  $solutions = Get-ChildItem -Path $PWD -Filter *.sln?
  if ($solutions.Count -gt 1) {
    throw "Multiple solution files found in the current directory. Please specify one using -TargetSolution."
  }
  elseif ($solutions.Count -eq 1) {
    $TargetSolution = $solutions[0].FullName
    Write-Host "  [INFO] Automatically detected solution file: $TargetSolution"
  }
  else {
    Write-Warning "No solution file found in the current directory. Project will not be added to a solution."
    $TargetSolution = $null
  }
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
$DestVcxproj = Join-Path $TargetFolder "$ProjectName.vcxproj"
$DestFilters = Join-Path $TargetFolder "$ProjectName.vcxproj.filters"

if (-not $DryRun) {
  if (-not (Test-Path -Path $TargetFolder)) {
    Write-Host "  Creating directory: $TargetFolder"
    New-Item -Path $TargetFolder -ItemType Directory | Out-Null
  }
  Copy-Item -Path $TemplateVcxproj -Destination $DestVcxproj
  Copy-Item -Path $TemplateFilters -Destination $DestFilters
}
Write-Host "  Copied '$TemplateVcxproj' to '$DestVcxproj'."
Write-Host "  Copied '$TemplateFilters' to '$DestFilters'."

# --- File Content Modification ---

Write-Host "Step 4: Modifying project file content..."
$NewGuid = ([guid]::NewGuid()).ToString('B').ToUpper()
$ConfigurationType = if ($ProjectType -eq 'StaticLib') { 'StaticLibrary' } else { 'Application' }

Write-Host "  New Project GUID: $NewGuid"
Write-Host "  New RootNamespace: $ProjectName"
Write-Host "  New ConfigurationType: $ConfigurationType"

if (-not $DryRun) {
  $vcxprojContent = Get-Content -Path $DestVcxproj -Raw
  $vcxprojContent = $vcxprojContent -replace '(<ProjectGuid>)(.*)(</ProjectGuid>)', "`$1$NewGuid`$3"
  $vcxprojContent = $vcxprojContent -replace '(<RootNamespace>)(.*)(</RootNamespace>)', "`$1$ProjectName`$3"
  $vcxprojContent = $vcxprojContent -replace '(<ConfigurationType>)(.*)(</ConfigurationType>)', "`$1$ConfigurationType`$3"
  Set-Content -Path $DestVcxproj -Value $vcxprojContent
}
Write-Host "  [OK] Successfully updated '$DestVcxproj' with new project details."

# --- Solution Integration ---

if ($TargetSolution) {
  Write-Host "Step 5: Adding new project to solution..."
  if ((Get-Command dotnet -ErrorAction SilentlyContinue)) {
    $dotnetCommand = "dotnet sln `"$TargetSolution`" add `"$DestVcxproj`""
    Write-Host "  Executing: $dotnetCommand"
    if (-not $DryRun) {
      Invoke-Expression -Command $dotnetCommand
    }
  }
  else {
    Write-Warning "The 'dotnet' command was not found. Please add the project to the solution manually."
  }
}

Write-Host "Project '$ProjectName' created successfully at '$TargetFolder'."