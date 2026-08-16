<#
.SYNOPSIS
    Provisions a clean Windows machine to build the WooCommerce Print Agent.

.DESCRIPTION
    Run this once on a build machine -- a Windows Server terminal, a VM, or any
    box where you have administrator rights. It installs everything
    `flutter build windows` and the Inno Setup packaging step require:

      * Visual Studio 2022 Build Tools + the "Desktop development with C++"
        workload. This is not optional and cannot be replaced by a portable
        MSVC: Flutter invokes Visual Studio's own bundled CMake and the
        "Visual Studio 17 2022" MSBuild generator, and hard-exits when it
        cannot find them via vswhere.
      * Inno Setup 6, which compiles installer\print_agent.iss.
      * Flutter (stable), unless it is already on PATH.
      * Developer Mode, so Flutter can create the plugin symlinks under
        windows\flutter\ephemeral\.plugin_symlinks.

    Nothing here is needed on a machine that only runs the built agent.

.PARAMETER FlutterVersion
    The Flutter stable version to install, e.g. 3.41.8. Required only when
    Flutter is not already on PATH. Keep it equal to FLUTTER_VERSION in
    .github\workflows\build-windows.yml so local and CI builds agree.

.PARAMETER FlutterRoot
    Where to unpack the Flutter SDK. Defaults to C:\src.

.PARAMETER SkipFlutter
    Leave Flutter alone entirely.

.EXAMPLE
    # In an ELEVATED PowerShell window:
    powershell -ExecutionPolicy Bypass -File tool\setup_build_machine.ps1 -FlutterVersion 3.41.8
#>

[CmdletBinding()]
param(
    [string]$FlutterVersion = '',
    [string]$FlutterRoot = 'C:\src',
    [switch]$SkipFlutter
)

$ErrorActionPreference = 'Stop'

function Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

$elevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $elevated) {
    throw @"
This script must run elevated -- installing the Visual Studio C++ toolchain
requires administrator rights.

Right-click PowerShell, choose "Run as administrator", then re-run:
  powershell -ExecutionPolicy Bypass -File tool\setup_build_machine.ps1

If you cannot get administrator rights on any machine, use the GitHub Actions
workflow in .github\workflows\build-windows.yml instead -- it builds the same
installer on a hosted runner that already has the toolchain.
"@
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw @"
winget was not found. On Windows Server it is not present by default.

Either install the App Installer package from
https://learn.microsoft.com/windows/package-manager/winget/ or install the
components by hand:
  * VS 2022 Build Tools  https://aka.ms/vs/17/release/vs_BuildTools.exe
                         (tick "Desktop development with C++")
  * Inno Setup 6         https://jrsoftware.org/isdl.php
  * Flutter (stable)     https://docs.flutter.dev/get-started/install/windows
"@
}

# ---------------------------------------------------------------------------
# Developer Mode -- lets Flutter create plugin symlinks without elevation later
# ---------------------------------------------------------------------------

Step "Enabling Developer Mode"

$unlockKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
if (-not (Test-Path $unlockKey)) {
    New-Item -Path $unlockKey -Force | Out-Null
}
Set-ItemProperty -Path $unlockKey `
    -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord
Write-Host "  Developer Mode is on." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Visual Studio 2022 Build Tools + C++ workload
# ---------------------------------------------------------------------------

Step "Installing the Visual Studio C++ toolchain"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$cppComponent = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'

function Test-CppToolchain {
    if (-not (Test-Path $vswhere)) { return $false }
    $found = & $vswhere -latest -products * -requires $cppComponent `
        -property installationPath
    return -not [string]::IsNullOrWhiteSpace($found)
}

if (Test-CppToolchain) {
    Write-Host "  Already present; skipping." -ForegroundColor DarkGray
} else {
    Write-Host "  This downloads several GB and can take 20-40 minutes." `
        -ForegroundColor Yellow

    # --includeRecommended pulls in the Windows SDK and "C++ CMake tools for
    # Windows", both of which Flutter checks for by component ID.
    $override = '--quiet --wait --norestart ' +
                '--add Microsoft.VisualStudio.Workload.VCTools ' +
                '--includeRecommended'

    winget install --id Microsoft.VisualStudio.2022.BuildTools `
        --accept-source-agreements --accept-package-agreements `
        --override $override

    # The VS bootstrapper returns 3010 to mean "installed, reboot pending".
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        throw "The Visual Studio Build Tools install failed (exit $LASTEXITCODE)."
    }

    if (-not (Test-CppToolchain)) {
        throw @"
The Build Tools installed but the C++ toolchain still is not detectable.
Open "Visual Studio Installer", choose Modify, and tick
"Desktop development with C++", then re-run this script.
"@
    }
    Write-Host "  C++ toolchain installed." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Inno Setup
# ---------------------------------------------------------------------------

Step "Installing Inno Setup 6"

$isccCandidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($iscc) {
    Write-Host "  Already present at $iscc" -ForegroundColor DarkGray
} else {
    winget install --id JRSoftware.InnoSetup `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "The Inno Setup install failed." }
}

# ---------------------------------------------------------------------------
# Flutter
# ---------------------------------------------------------------------------

if (-not $SkipFlutter) {
    Step "Installing Flutter"

    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        Write-Host "  Already on PATH; skipping." -ForegroundColor DarkGray
        Write-Host "  (pass -SkipFlutter to silence this check)" -ForegroundColor DarkGray
    } else {
        # Flutter is not distributed through winget, so the SDK archive is
        # fetched straight from Google's release bucket and unpacked. This needs
        # no elevation, which is also why it is safe to point -FlutterRoot at a
        # user-writable folder.
        if (-not $FlutterVersion) {
            throw @"
No Flutter found and no -FlutterVersion given.

Re-run with the version you want pinned, for example:
  tool\setup_build_machine.ps1 -FlutterVersion 3.41.8

Use the same version as .github\workflows\build-windows.yml so local and CI
builds agree.
"@
        }

        if (-not (Test-Path $FlutterRoot)) {
            New-Item -ItemType Directory -Path $FlutterRoot -Force | Out-Null
        }

        $zipUrl = 'https://storage.googleapis.com/flutter_infra_release/releases' +
                  "/stable/windows/flutter_windows_$FlutterVersion-stable.zip"
        $zipPath = Join-Path $env:TEMP "flutter_windows_$FlutterVersion-stable.zip"

        Write-Host "  Downloading $zipUrl" -ForegroundColor DarkGray
        Write-Host "  (about 1 GB; this takes a few minutes)" -ForegroundColor Yellow

        # Invoke-WebRequest's progress bar makes large downloads crawl in 5.1.
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            throw @"
Could not download Flutter $FlutterVersion.

Check that the version exists at
https://docs.flutter.dev/release/archive (Windows, stable channel).

Underlying error: $($_.Exception.Message)
"@
        } finally {
            $ProgressPreference = $previousProgress
        }

        Write-Host "  Extracting to $FlutterRoot" -ForegroundColor DarkGray
        Expand-Archive -Path $zipPath -DestinationPath $FlutterRoot -Force
        Remove-Item $zipPath -Force

        # The archive contains a top-level `flutter\` folder.
        $flutterBin = Join-Path $FlutterRoot 'flutter\bin'
        if (-not (Test-Path (Join-Path $flutterBin 'flutter.bat'))) {
            throw "Extraction finished but $flutterBin\flutter.bat is missing."
        }

        # Persist on PATH for this user, and make it usable in this session too.
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$flutterBin*") {
            [Environment]::SetEnvironmentVariable(
                'Path', "$userPath;$flutterBin", 'User')
            Write-Host "  Added $flutterBin to your PATH." -ForegroundColor DarkGray
        }
        $env:Path = "$env:Path;$flutterBin"

        Write-Host "  Flutter $FlutterVersion installed." -ForegroundColor Green
        Write-Host "  Open a NEW shell so PATH picks up flutter." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Build machine ready." -ForegroundColor Green
Write-Host ""
Write-Host "Open a new PowerShell window (so PATH is refreshed) and run:"
Write-Host "  flutter doctor -v                # 'Visual Studio' must be green"
Write-Host "  tool\build_release.ps1           # release build + installer"
Write-Host ""
Write-Host "The installer is written to installer\Output."
