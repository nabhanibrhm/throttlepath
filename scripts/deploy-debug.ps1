# Builds a DEBUG APK and installs+runs it on the connected phone.
# Debug is what goes on the device for day-to-day testing.
#   Usage:  ./scripts/deploy-debug.ps1
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

Write-Host "==> Building & installing DEBUG on device..." -ForegroundColor Cyan
# secrets.json (git-ignored) carries CARTO_KEY; without it the maps show
# CARTO's "API KEY REQUIRED" watermark.
if (Test-Path "secrets.json") {
  flutter run --debug --dart-define-from-file=secrets.json
} else {
  Write-Warning "secrets.json missing - maps will show CARTO's API-key watermark."
  flutter run --debug
}
