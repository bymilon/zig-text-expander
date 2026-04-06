param(
  [string]$ExePath = ".\\dist\\text-expander.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ExePath)) {
  throw "Executable not found at $ExePath. Run scripts/build-release.ps1 first."
}

& $ExePath run
