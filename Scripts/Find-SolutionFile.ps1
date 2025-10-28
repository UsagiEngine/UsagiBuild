<#
.SYNOPSIS
  Finds a solution file (.sln or .slnx) in a specified directory.
.DESCRIPTION
  This script searches the specified directory for a .sln or .slnx file. It handles
  cases where zero, one, or multiple solution files are found.
.PARAMETER Directory
  The directory to search in. Defaults to the current working directory.
.OUTPUTS
  [string] The full path to the solution file if exactly one is found.
  $null if no solution file is found.
.NOTES
  The script will throw an error if more than one solution file is found to
  prevent ambiguity.
#>
[CmdletBinding()]
param(
  [string]$Directory = $PWD
)

$searchPath = (Resolve-Path -Path $Directory).Path
Write-Host "  [INFO] Searching for solution file in: '$searchPath'"
$solutions = Get-ChildItem -Path $searchPath -Include "*.sln", "*.slnx" -File

if ($solutions.Count -gt 1) {
    throw "Multiple solution files found in '$searchPath'. Please specify one explicitly."
}

if ($solutions.Count -eq 1) {
    Write-Host "  [INFO] Automatically detected solution file: $($solutions[0].FullName)"
    return $solutions[0].FullName
}

Write-Warning "No solution file found in '$searchPath'."
return $null
