# WooCommerce Print Agent

A production Windows desktop agent that connects a WooCommerce store's Print
Management plugin to the printers attached to a local computer.

```
WooCommerce Print Management Plugin
        ↓ HTTPS, token-authenticated
   Secure Print Queue (server side)
        ↓ poll · claim · report
Flutter Windows Print Agent   ←── this repository
        ↓ Win32 Print Spooler
   Local Windows Printers
```

It is **store-agnostic, printer-agnostic and vendor-agnostic**. There are no
hard-coded store URLs, printer models, carriers or shipping providers anywhere
in the codebase: printers are discovered from Windows at runtime, and the store
is configured by the operator during pairing.

---

## What it does

| | |
|---|---|
| **Pairs securely** | An administrator approves the device in wp-admin using a short-lived code. The agent never asks for a WordPress username or password. |
| **Stores credentials safely** | Tokens are encrypted with the Windows Data Protection API, bound to the signed-in user, and never written to the database or a log. |
| **Discovers printers** | `EnumPrintersW` at level 2 — name, driver, port, connection type, default flag, live status. |
| **Prints anything generic** | PDF, PNG, JPEG, HTML, plain text and raw printer data, through a pluggable strategy layer. |
| **Never prints twice** | Four independent guards: a database uniqueness constraint, a pre-spool state check, a per-process print lease, and `Idempotency-Key` on every report. |
| **Survives restarts** | A persistent SQLite queue. A job caught mid-print becomes *Needs review* rather than being silently reprinted. |
| **Survives outages** | Offline is a first-class state. Queued work is preserved, terminal outcomes are replayed on reconnect, and polling backs off instead of hammering. |
| **Runs unattended** | System tray presence, start-with-Windows, minimise-to-tray, and a single-instance guard. |
| **Explains itself** | Structured redacted logs, an in-app viewer with export, and a diagnostics suite that tests the connection, authorisation, printers and renderers end to end. |

---

## Screens

| Screen | Purpose |
|---|---|
| **Dashboard** | Connection, printers, queue counters and recent jobs at a glance. |
| **Print queue** | Live jobs, retries, failures and the *Needs review* prompt. |
| **Printers** | Inventory, per-printer profile assignment, enable/disable, test print. |
| **History** | Archived jobs with filtering. |
| **Diagnostics** | Full environment report plus a one-click test suite. |
| **Settings** | General, connection, printing, logs, updates, disconnect. |

---

## Getting started

```powershell
git clone <your-repo> flutter-app
cd flutter-app

flutter pub get
dart run build_runner build --delete-conflicting-outputs   # freezed / json_serializable

flutter run -d windows
```

To produce the installable `.exe`:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
# -> installer\Output\PrintAgent-Setup-<version>.exe
```

That needs Visual Studio 2022's **Desktop development with C++** workload and
Inno Setup 6, both of which require administrator rights to install. **If you
don't have admin**, push the repository and let
[`.github/workflows/build-windows.yml`](.github/workflows/build-windows.yml)
build it — the GitHub-hosted Windows runner already has the toolchain, and the
installer comes back as a downloadable artifact. To provision a build machine
you *do* control, run `tool\setup_build_machine.ps1` on it once.

Full instructions are in [`docs/BUILD.md`](docs/BUILD.md).

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Layering, runtime topology, error/retry strategy, extensibility. |
| [`docs/API_INTEGRATION.md`](docs/API_INTEGRATION.md) | The complete REST contract the WordPress plugin must implement. |
| [`docs/DATABASE_SCHEMA.md`](docs/DATABASE_SCHEMA.md) | Every table, index and the job state machine. |
| [`docs/PRINT_PIPELINE.md`](docs/PRINT_PIPELINE.md) | Printer abstraction, strategies, and the end-to-end job pipeline. |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Threat model and the rules the code is held to. |
| [`docs/BUILD.md`](docs/BUILD.md) | Build, package and deploy. |
| [`docs/DEVELOPER.md`](docs/DEVELOPER.md) | Codebase tour, conventions, and how to extend it. |

---

## Technology

| Concern | Choice |
|---|---|
| UI state | Riverpod |
| Service lifetimes / DI | GetIt |
| Windows APIs | `dart:ffi` bindings to winspool, crypt32, advapi32, kernel32 |
| Local database | SQLite (`sqflite_common_ffi`) |
| Networking | Dio |
| Models | Freezed + json_serializable |
| Routing | go_router |
| Rendering | PDFium via `printing`, page composition via `pdf` |

Riverpod and GetIt are **not** used interchangeably: GetIt owns infrastructure
and application services, Riverpod owns reactive UI state, and a service never
reads a provider. See `lib/core/di/service_locator.dart`.

---

## Project layout

```
lib/
├── core/          config · di · errors · logging · network · platform ·
│                  security · storage · theme · utils · widgets
├── features/      authentication · agent · printers · print_queue · printing ·
│                  dashboard · history · diagnostics · settings
├── routing/       go_router configuration and the app shell
├── services/      api · printer · queue · background · updater
├── bootstrap.dart ordered startup
├── app.dart       MaterialApp.router
└── main.dart      single-instance guard, window, tray, lifecycle
```

---

## Status

Everything in the specification is implemented except the update *transport*:
`UpdateService` is a fully-specified interface with a deliberate no-op
implementation, because shipping a half-built auto-updater that downloads and
executes binaries would be a liability rather than a feature. The seam is there;
see `lib/services/updater/update_service.dart` for the contract a real
implementation must satisfy.
