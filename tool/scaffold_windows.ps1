<#
.SYNOPSIS
    Generates the Flutter Windows platform folder for this project.

.DESCRIPTION
    This repository contains the application source (lib/, test/, docs/,
    installer/) but not the generated `windows/` runner, because that folder is
    machine-generated boilerplate that should track your installed Flutter
    version rather than being pinned in source control.

    Run this once after cloning. It:
      1. backs up lib/ and pubspec.yaml (belt and braces -- `flutter create`
         skips existing files, but a backup costs nothing),
      2. runs `flutter create --platforms=windows .`,
      3. restores anything that was overwritten,
      4. points the runner at the bundled application icon.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\scaffold_windows.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

Write-Host "Project root: $projectRoot" -ForegroundColor Cyan

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not on PATH. Install Flutter and try again."
}

# `flutter create` links plugins with symlinks, which needs Developer Mode or an
# elevated shell. Say so now rather than letting it fail halfway through.
$devMode = $false
try {
    $unlock = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
        -ErrorAction Stop
    $devMode = ($unlock.AllowDevelopmentWithoutDevLicense -eq 1)
} catch {
    $devMode = $false
}
$elevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $devMode -and -not $elevated) {
    Write-Host "Developer Mode is off and this shell is not elevated." -ForegroundColor Yellow
    Write-Host "Plugin symlinks will fail. Enable it with: start ms-settings:developers" -ForegroundColor Yellow
}

$backupDir = $null
if (-not $SkipBackup) {
    $backupDir = Join-Path $projectRoot ".scaffold-backup"
    if (Test-Path $backupDir) { Remove-Item $backupDir -Recurse -Force }
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    Copy-Item -Path (Join-Path $projectRoot 'lib') -Destination $backupDir -Recurse
    Copy-Item -Path (Join-Path $projectRoot 'pubspec.yaml') -Destination $backupDir
    Write-Host "Backed up lib/ and pubspec.yaml to .scaffold-backup" -ForegroundColor DarkGray
}

Write-Host "Generating the Windows runner..." -ForegroundColor Cyan
flutter create --platforms=windows --project-name wc_print_agent --org com.example .
if ($LASTEXITCODE -ne 0) { throw "flutter create failed." }

if ($backupDir) {
    # `flutter create` will not overwrite existing files, but if it ever does,
    # the originals win -- the generated main.dart is a counter demo.
    Copy-Item -Path (Join-Path $backupDir 'lib\*') `
              -Destination (Join-Path $projectRoot 'lib') -Recurse -Force
    Copy-Item -Path (Join-Path $backupDir 'pubspec.yaml') `
              -Destination $projectRoot -Force
    Remove-Item $backupDir -Recurse -Force
    Write-Host "Restored application sources." -ForegroundColor DarkGray
}

# `flutter create` also drops a counter-demo widget test and IDE project files
# that have nothing to do with this application; they would fail `flutter test`.
foreach ($cruft in @('test\widget_test.dart', 'wc_print_agent.iml', '.idea')) {
    $path = Join-Path $projectRoot $cruft
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "Removed generated $cruft" -ForegroundColor DarkGray
    }
}

# Point the runner at the real application icon.
$iconSource = Join-Path $projectRoot 'assets\icons\app_icon.ico'
$iconTarget = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
if ((Test-Path $iconSource) -and (Test-Path (Split-Path $iconTarget))) {
    Copy-Item $iconSource $iconTarget -Force
    Write-Host "Installed the application icon into the runner." -ForegroundColor DarkGray
}

# Give the window a real title instead of the generated project name.
$mainCpp = Join-Path $projectRoot 'windows\runner\main.cpp'
if (Test-Path $mainCpp) {
    $content = Get-Content $mainCpp -Raw
    $updated = $content -replace 'window\.Create\(L"wc_print_agent"', 'window.Create(L"WooCommerce Print Agent"'
    if ($updated -ne $content) {
        Set-Content -Path $mainCpp -Value $updated -NoNewline
        Write-Host "Set the window title." -ForegroundColor DarkGray
    }
}

Write-Host "Fetching packages..." -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

Write-Host "Running code generation (freezed / json_serializable)..." -ForegroundColor Cyan
dart run build_runner build --delete-conflicting-outputs
if ($LASTEXITCODE -ne 0) { throw "build_runner failed." }

Write-Host ""
Write-Host "Done. Next:" -ForegroundColor Green
Write-Host "  flutter run -d windows          # debug"
Write-Host "  tool\build_release.ps1          # release build + installer"
