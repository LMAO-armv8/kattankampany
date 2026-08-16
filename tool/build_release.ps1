<#
.SYNOPSIS
    Builds the Windows release and, if Inno Setup is installed, the installer.

.PARAMETER SkipInstaller
    Build the application only.

.PARAMETER SkipTests
    Skip the analyzer and test run. Not recommended for a release you intend to
    ship.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipInstaller,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

function Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

if (-not (Test-Path (Join-Path $projectRoot 'windows'))) {
    throw "The windows/ folder is missing. Run tool\scaffold_windows.ps1 first."
}

# ---------------------------------------------------------------------------
# Preflight. Both of these fail deep inside the toolchain with messages that do
# not name the real cause, so they are checked up front.
# ---------------------------------------------------------------------------

Step "Checking the build environment"

# 1. Symlink support. `flutter build windows` links each plugin into
#    windows\flutter\ephemeral\.plugin_symlinks. Creating a symlink needs either
#    Developer Mode or an elevated shell.
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
    # Literal here-string: the message contains no variables, and @'...'@ avoids
    # backticks in the text being treated as escape characters.
    throw @'
This build needs permission to create symbolic links, which Flutter uses to
link plugins into windows\flutter\ephemeral\.plugin_symlinks.

Fix it either way:
  * Enable Developer Mode (preferred, one-off):  start ms-settings:developers
  * or re-run this script from an elevated PowerShell window.
'@
}
Write-Host "  Symlink support: OK$(if (-not $devMode) { ' (via elevation)' })" `
    -ForegroundColor DarkGray

# 2. The MSVC toolchain. Flutter compiles the C++ runner with it; without the
#    "Desktop development with C++" workload there is no way to produce an exe.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCppToolchain = $false
if (Test-Path $vswhere) {
    $found = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    $hasCppToolchain = -not [string]::IsNullOrWhiteSpace($found)
}
if (-not $hasCppToolchain) {
    throw @'
Visual Studio's C++ toolchain was not found. Flutter cannot build a Windows
executable without it, and a portable/standalone MSVC will not do: Flutter
invokes Visual Studio's own bundled CMake and the "Visual Studio 17 2022"
MSBuild generator, located through vswhere.

On a machine where you have administrator rights, run:

  tool\setup_build_machine.ps1 -FlutterVersion 3.41.8

If you have no administrator rights anywhere, build in CI instead -- see
.github\workflows\build-windows.yml, which runs on a GitHub-hosted Windows
runner that already has the toolchain.

Verify with: flutter doctor
'@
}
Write-Host "  C++ toolchain:   OK" -ForegroundColor DarkGray

Step "Fetching packages"
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

Step "Running code generation"
dart run build_runner build --delete-conflicting-outputs
if ($LASTEXITCODE -ne 0) { throw "build_runner failed." }

if (-not $SkipTests) {
    Step "Analysing"
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw "Analysis reported problems." }

    Step "Running tests"
    flutter test
    if ($LASTEXITCODE -ne 0) { throw "Tests failed." }
}

Step "Building the Windows release"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed." }

$releaseDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $releaseDir 'wc_print_agent.exe'))) {
    throw "The release executable was not produced at $releaseDir."
}
Write-Host "Release output: $releaseDir" -ForegroundColor Green

if ($SkipInstaller) {
    Write-Host "Skipping the installer as requested." -ForegroundColor Yellow
    return
}

Step "Building the installer"

# Keep the installer version in step with pubspec.yaml so the Programs and
# Features entry always matches the running build. Passed to ISCC as /DAppVersion
# rather than rewritten into the .iss, so the script stays a read-only input and
# a failed build cannot leave the repository dirty.
$version = $null
$pubspec = Get-Content (Join-Path $projectRoot 'pubspec.yaml') -Raw
if ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    $version = $Matches[1]
    Write-Host "Installer version: $version" -ForegroundColor DarkGray
} else {
    throw "Could not read a version from pubspec.yaml."
}

$iscc = $null
foreach ($candidate in @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe"
)) {
    if (Test-Path $candidate) { $iscc = $candidate; break }
}
if (-not $iscc) {
    # Windows PowerShell 5.1 has no null-conditional operator, so resolve the
    # command first and only then read .Source.
    $isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($isccCommand) { $iscc = $isccCommand.Source }
}

if (-not $iscc) {
    Write-Host "Inno Setup 6 was not found -- skipping the installer." -ForegroundColor Yellow
    Write-Host "Install it from https://jrsoftware.org/isdl.php and re-run." -ForegroundColor Yellow
    return
}

& $iscc "/DAppVersion=$version" (Join-Path $projectRoot 'installer\print_agent.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed." }

Write-Host ""
Write-Host "Installer written to installer\Output" -ForegroundColor Green
Get-ChildItem (Join-Path $projectRoot 'installer\Output') -Filter *.exe |
    ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length/1MB,1)) MB)" }
