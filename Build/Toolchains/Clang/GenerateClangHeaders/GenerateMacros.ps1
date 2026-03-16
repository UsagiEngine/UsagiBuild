param(
    [Parameter(Mandatory=$true)]
    [string]$ClangClPath,

    [Parameter(Mandatory=$true)]
    [string]$ClangArgs,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
)

# Shio:
# This script wraps the invocation of clang-cl to generate the built-in macros file.
# It resolves the race conditions and file-locking issues that occur when using multiple
# sequential `Exec` tasks to stream output via `>` and `>>` inside MSBuild.
#
# Background:
# We explicitly pass -xc++ because piping an empty string makes Clang assume we are
# providing C source code, which throws an error when it sees '-std=c++26'.
#
# Because the ClangArgs passed here explicitly include the '/clang:-dM /E -' flags,
# piping empty input forces Clang to evaluate the target architecture (like -march=skylake)
# and dump all resultant predefined macros (like __BMI__, __AVX2__).
#
# We wrap the output in #ifdef __RESHARPER__ so that during normal compilation via forced
# includes, these macros do not trigger redefinition warnings.

$ErrorActionPreference = 'Stop'

try {
    Write-Host "Invoking clang-cl to dump predefined macros..."
    
    # We pipe an empty string to standard input and capture the output.
    # We use Invoke-Expression or & to run the executable and capture stdout.
    
    # Convert string arguments into an array so PowerShell can safely pass them to the executable
    # Note: ClangArgs comes in as a string like "-xc++ /std:c++26 /clang:-dM /E -".
    # We split it by space.
    $ArgList = @("-xc++") + ($ClangArgs -split '\s+' | Where-Object { $_ -ne '' })
    
    # We use Start-Process with NoNewWindow and RedirectStandardOutput for safe capture,
    # or just use the call operator with input redirection
    
    $Macros = "" | & $ClangClPath $ArgList 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "clang-cl exited with code $LASTEXITCODE. Output: $Macros"
        exit $LASTEXITCODE
    }
    
    # Now, write the file cleanly with a single, atomic file operation.
    $Content = "#ifdef __RESHARPER__`n"
    $Content += ($Macros -join "`n")
    $Content += "`n#endif`n"
    
    Set-Content -Path $OutputFile -Value $Content -Encoding UTF8 -Force
    
    Write-Host "Successfully generated '$OutputFile'."
    exit 0
}
catch {
    Write-Error "Failed to generate cpp hint macros: $_"
    exit 1
}
