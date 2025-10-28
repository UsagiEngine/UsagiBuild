<#
.SYNOPSIS
  Adds a project to a Visual Studio solution file.
.DESCRIPTION
  This script uses the 'dotnet sln' command to add a specified .vcxproj file
  to a .sln or .slnx file.
.PARAMETER SolutionPath
  The full path to the solution file.
.PARAMETER ProjectPath
  The full path to the project file (.vcxproj) to add.
.PARAMETER DryRun
  If specified, the script will log the command it would run without executing it.
#>

# Shio: TODO: The 'dotnet sln add' command is known to fail for native C++ projects
# (.vcxproj) when not run from a Visual Studio Developer Command Prompt. It cannot
# resolve MSBuild properties like `$(VCTargetsPath)` which are essential for C++
# projects.
#
# Potential future solutions:
# 1. Manually parse and edit the .sln/.slnx file to add the project entry. This
#    is complex but would be the most robust, environment-independent solution.
# 2. Attempt to find and invoke MSBuild.exe directly from a standard PowerShell
#    session, which is less portable.
# 3. Require the user to run this script from a VS Developer Command Prompt.
#
# For now, we will keep the current implementation and accept its limitations.

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$SolutionPath,

  [Parameter(Mandatory=$true)]
  [string]$ProjectPath,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $SolutionPath -PathType Leaf)) {
    throw "Solution file not found at '$SolutionPath'."
}
if (-not (Test-Path -Path $ProjectPath -PathType Leaf)) {
    throw "Project file not found at '$ProjectPath'."
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Warning "The 'dotnet' command was not found. Cannot add project to solution."
    return
}

$dotnetCommand = "dotnet sln `"$SolutionPath`" add `"$ProjectPath`""
Write-Host "  Executing: $dotnetCommand"
if (-not $DryRun) {
    Invoke-Expression -Command $dotnetCommand
}
