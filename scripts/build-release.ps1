param(
  [string]$ZigExe = "zig"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath "dist")) {
  New-Item -ItemType Directory -Path "dist" | Out-Null
}

& $ZigExe build-exe src/main.zig -O ReleaseSafe -lc -luser32 -femit-bin=dist/text-expander.exe

Write-Host "Built dist/text-expander.exe"
