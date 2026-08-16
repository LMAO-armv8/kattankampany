# Building, packaging and deploying

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10 1809 (build 17763) or newer, 64-bit | The minimum the installer allows. |
| Flutter **3.27** or newer (stable) | `flutter --version`. Older versions lack `Color.withValues`. |
| Visual Studio 2022 with **Desktop development with C++** | Required by every Flutter Windows build. The "C++ CMake tools for Windows" component must be present. |
| **Developer Mode**, or an elevated shell | Flutter symlinks each plugin into `windows\flutter\ephemeral\.plugin_symlinks`. |
| [Inno Setup 6](https://jrsoftware.org/isdl.php) | Only needed to build the installer. |

Confirm the toolchain first:

```powershell
flutter doctor -v
```

`[√] Visual Studio - develop Windows apps` must be green before anything else
will work.

### If you do not have administrator rights

Installing the Visual Studio C++ toolchain requires administrator rights, and
there is no way around it for a Flutter Windows build. A portable/standalone
MSVC (PortableBuildTools, `xwin`, and similar) is **not** a substitute, because
Flutter does not merely invoke `cl.exe`:

* `flutter_tools/.../visual_studio.dart` locates the install by running
  `vswhere.exe` from `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\`;
* it then uses **Visual Studio's own bundled CMake**, at
  `<installPath>\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`;
* and generates with `-G "Visual Studio 17 2022"`, i.e. MSBuild;
* `build_windows.dart` hard-exits with *"Unable to find suitable Visual Studio
  toolchain"* when either is missing.

Making a portable toolchain satisfy all of that means patching `flutter_tools`
and re-patching it after every Flutter upgrade. Use one of these instead:

| Option | When to use it |
|---|---|
| **GitHub Actions** — `.github/workflows/build-windows.yml` | No admin anywhere. The `windows-latest` runner already has VS 2022 with the C++ workload. Push the repo, then download `PrintAgent-Setup-<version>.exe` from the run's Artifacts. Tagging `v1.0.0` also attaches it to a GitHub Release. |
| **A build machine you do control** — a Windows Server terminal or VM | Run `tool\setup_build_machine.ps1` there once (elevated); it installs the C++ Build Tools, Inno Setup, Developer Mode and, if needed, Flutter. Then `tool\build_release.ps1` as normal. |

Neither option requires changing anything on a locked-down workstation. You can
still develop, analyse and test locally without the C++ toolchain — only
`flutter build windows` and `flutter run -d windows` need it.

---

## 2. First-time setup

The generated `windows/` runner folder **is** committed, so a clone is ready to
build. You only need:

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

### Regenerating the runner

`tool\scaffold_windows.ps1` recreates `windows/` from scratch — worth doing after
a major Flutter upgrade, when the runner template has changed:

```powershell
powershell -ExecutionPolicy Bypass -File tool\scaffold_windows.ps1
```

It backs up `lib/` and `pubspec.yaml`, runs `flutter create --platforms=windows .`,
restores the application sources, deletes the generated counter-demo
`test\widget_test.dart` and IDE files, installs the bundled icon into
`windows\runner\resources\app_icon.ico`, sets the window title, fetches packages
and runs code generation.

> `flutter create` skips files that already exist, so it will not clobber
> `lib/main.dart`. The scaffold script keeps a backup anyway.

---

## 3. Code generation

Freezed and json_serializable produce the `*.freezed.dart` and `*.g.dart` part
files. They are **not** committed (see `.gitignore`), so generation is required
after a clone and after any change to a model.

```powershell
dart run build_runner build --delete-conflicting-outputs
```

While working on models:

```powershell
dart run build_runner watch --delete-conflicting-outputs
```

Generated files exist for:

```
lib/core/config/app_settings.dart
lib/features/agent/domain/agent.dart
lib/features/agent/domain/store_connection.dart
lib/features/print_queue/domain/print_job.dart
lib/features/printers/domain/print_profile.dart
lib/features/printers/domain/printer_device.dart
```

---

## 4. Running in development

```powershell
flutter run -d windows
```

Debug builds write logs to the console *and* to
`%APPDATA%\WooCommercePrintAgent\logs\agent.log`.

To test the sign-in launch path:

```powershell
flutter run -d windows --dart-entrypoint-args --startup
```

---

## 5. Tests and analysis

```powershell
flutter analyze
flutter test
```

The tests run on the Dart VM with an in-memory SQLite database and fake
printer/network layers, so they pass on any host — no printer required.

For coverage:

```powershell
flutter test --coverage
```

---

## 6. Release build

```powershell
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`

```
wc_print_agent.exe
flutter_windows.dll
sqlite3.dll                 (sqlite3_flutter_libs)
printing_plugin.dll         (PDFium)
tray_manager_plugin.dll
window_manager_plugin.dll
url_launcher_windows_plugin.dll
file_selector_windows_plugin.dll
connectivity_plus_plugin.dll
data\                       (Flutter assets and ICU data)
```

**Everything in that folder must be distributed together.** The executable will
not start without `flutter_windows.dll` and `data\`.

### Version information

The Windows file-version resource is generated from `pubspec.yaml`'s
`version: 1.0.0+1` by the Flutter runner's `Runner.rc`. Bump the version there
and rebuild; `build_release.ps1` also syncs the Inno Setup script to match.

---

## 7. Installer

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
```

That script runs `pub get` → code generation → analyze → test → release build →
Inno Setup, and writes `installer\Output\PrintAgent-Setup-<version>.exe`.

To build only the installer against an existing release output:

```powershell
iscc installer\print_agent.iss
```

### What the installer does

* Installs per-user by default (`PrivilegesRequired=lowest`). No administrator
  rights are needed, because the agent only writes to `HKEY_CURRENT_USER` and
  needs the interactive desktop session anyway — a machine-level service cannot
  see printers the operator connected as themselves.
  Pass `/ALLUSERS` for a machine-wide deployment.
* Creates a Start menu entry, an optional desktop shortcut, and an optional
  `Run` registry entry for start-with-Windows.
* Closes a running agent before replacing files, and offers to start it after.
* On uninstall, removes the program files and the `Run` entry, then **asks**
  whether to delete `%APPDATA%\WooCommercePrintAgent`. Answering *No* keeps the
  queue, history and pairing so a reinstall does not require re-pairing.

### Before you ship

Edit the top of `installer\print_agent.iss`:

```
#define AppPublisher   "Your Company"
#define AppURL         "https://example.com"
```

and generate your **own** `AppId` GUID — the one in the file is a placeholder
and two products sharing an `AppId` will uninstall each other.

### Code signing

Unsigned installers trigger SmartScreen. With a code-signing certificate:

```powershell
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
  /f mycert.pfx /p <password> `
  build\windows\x64\runner\Release\wc_print_agent.exe

# then rebuild the installer and sign it too
iscc installer\print_agent.iss
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
  /f mycert.pfx /p <password> installer\Output\PrintAgent-Setup-1.0.0.exe
```

Inno Setup can also do this automatically via `SignTool=` — see its docs.

---

## 8. Silent deployment

For rolling out to many machines:

```powershell
PrintAgent-Setup-1.0.0.exe /VERYSILENT /NORESTART /TASKS="startupicon"
```

Useful switches:

| Switch | Effect |
|---|---|
| `/VERYSILENT` | No UI at all. |
| `/SUPPRESSMSGBOXES` | Suppress prompts. |
| `/DIR="C:\Apps\PrintAgent"` | Custom install location. |
| `/TASKS="startupicon,desktopicon"` | Select optional tasks. |
| `/ALLUSERS` | Machine-wide install (needs elevation). |
| `/LOG="C:\temp\install.log"` | Write an install log. |

Each machine still has to be paired once by an administrator, because pairing is
deliberately an explicit, human-approved step.

---

## 9. Where the agent stores things

```
%APPDATA%\WooCommercePrintAgent\
├── agent.db            SQLite: agent, printers, profiles, queue, history, settings, logs
├── credentials\        DPAPI-encrypted tokens (one file per agent)
├── logs\               agent.log + up to 4 rotated files
└── documents\          transient print payloads, pruned after 24 h
```

Nothing sensitive is written anywhere else. Removing that folder resets the
agent completely.

---

## 10. Troubleshooting the build

| Symptom | Cause and fix |
|---|---|
| `CMake Error ... MSVC` | Visual Studio's C++ desktop workload is missing. Install it via the VS Installer. |
| `Target of URI hasn't been generated: 'x.freezed.dart'` | Code generation has not run. `dart run build_runner build --delete-conflicting-outputs`. |
| `Undefined name 'withValues'` | Flutter older than 3.27. Upgrade, or replace `withValues(alpha: x)` with `withOpacity(x)`. |
| `sqlite3.dll not found` at runtime | `sqlite3_flutter_libs` was not fetched, or you copied the `.exe` without the rest of the Release folder. |
| Tray icon missing | `assets/icons/tray.ico` was not bundled. Check the `assets:` block in `pubspec.yaml` and rebuild. |
| Build succeeds, app closes instantly | Another instance is already running (the single-instance mutex). Check the notification area. |
| `flutter build windows` cannot find the project | The `windows\` folder is missing. Run `tool\scaffold_windows.ps1`. |
| `Building with plugins requires symlink support` | Developer Mode is off. `start ms-settings:developers`, or run the build from an elevated shell. |
| `Unable to find suitable Visual Studio toolchain` | The C++ workload is missing. See [§1, *If you do not have administrator rights*](#if-you-do-not-have-administrator-rights). |
| A `tool\*.ps1` script dies with *"string is missing the terminator"* | The file picked up a non-ASCII character (a typographic dash or curly quote) and Windows PowerShell 5.1 read it as ANSI. Keep these scripts ASCII-only. |
