# WooCommerce Print Agent — Architecture

Version: 1.0.0
Target: Windows 10 / 11 desktop (x64), Flutter stable.

---

## 1. Purpose

The Print Agent is the local half of a commercial WooCommerce printing platform:

```
WooCommerce Print Management Plugin
        ↓ (secure REST API, HTTPS)
   Secure Print Queue (server side)
        ↓ (poll / claim / report)
Flutter Windows Print Agent   ←── this application
        ↓ (Win32 Print Spooler)
   Local Windows Printers
```

The agent is **store-agnostic, printer-agnostic and vendor-agnostic**. It contains no
hard-coded store URLs, printer names, models, carriers or shipping providers. Everything
device-specific is discovered at runtime; everything store-specific is configured by the
operator during pairing.

---

## 2. Layering

The codebase uses clean architecture with a strict dependency direction:

```
presentation  →  domain  ←  data / services
     │                          │
     └──────→  core  ←──────────┘
```

* **core** — cross-cutting infrastructure with no feature knowledge: config, DI,
  errors, logging, networking primitives, security, SQLite storage, utilities, theme.
* **domain** — immutable models, enums and abstract contracts. Pure Dart, no Flutter,
  no I/O. Fully unit-testable.
* **data / services** — concrete implementations of the domain contracts: the REST
  client, SQLite DAOs, the Win32 printer service, the queue engine, background
  services. May depend on `core` and `domain`, never on `presentation`.
* **presentation** — Flutter widgets and Riverpod controllers. Depends on `domain`
  contracts and reads services through DI. Never talks to Dio, SQLite or Win32
  directly.

### Directory map

```
lib/
├── main.dart                     entry point, single-instance guard, window setup
├── app.dart                      MaterialApp.router + theme
├── bootstrap.dart                ordered async startup of all subsystems
│
├── core/
│   ├── config/                   AppConfig, AppInfo, runtime environment
│   ├── di/                       GetIt service locator registration
│   ├── errors/                   AppException hierarchy, Failure, user-facing messages
│   ├── logging/                  structured logger, sinks, rotation, redaction
│   ├── network/                  Dio client, endpoints, interceptors, connectivity
│   ├── security/                 DPAPI credential store, pairing codes, URL/doc validation
│   ├── storage/                  Database, migrations, DAOs
│   ├── theme/                    design tokens, light/dark themes
│   └── utils/                    Result, RetryPolicy, ids, formatting
│
├── features/                     UI + feature-scoped domain
│   ├── authentication/           pairing, credentials, connect-your-store flow
│   ├── agent/                    agent identity, registration, heartbeat state
│   ├── printers/                 printer list, profiles, test print UI
│   ├── print_queue/              job model, queue screen
│   ├── printing/                 print request/result domain types
│   ├── settings/                 settings model + screen
│   ├── dashboard/                dashboard screen and widgets
│   ├── diagnostics/              diagnostics model + screen
│   └── history/                  completed job history screen
│
├── routing/                      go_router configuration and shell
│
└── services/                     infrastructure implementations
    ├── api/                      PrintAgentApi + DTOs
    ├── printer/                  PrinterService, Win32 FFI, strategies, manager
    ├── queue/                    queue repository, engine, processor, downloader
    ├── background/               sync, heartbeat, tray, autostart, lifecycle
    └── updater/                  UpdateService abstraction
```

---

## 3. State management and dependency injection

Two tools, two jobs, never mixed:

| Concern | Tool | Rule |
|---|---|---|
| Long-lived infrastructure and application services | **GetIt** | Registered once in `configureDependencies()`. Services know nothing about Riverpod or Flutter. |
| Reactive UI state | **Riverpod** | Providers wrap GetIt services and expose streams/snapshots to widgets. |

A Riverpod provider may call `sl<SomeService>()`; a service must **never** read a
Riverpod provider. This keeps the service layer headless — the agent continues to work
with no window open, and services can be unit-tested without a `ProviderContainer`.

Services publish state as broadcast `Stream`s. Riverpod adapts those streams with
`StreamProvider`, so the UI is a pure projection of service state and closing the window
cannot stall printing.

---

## 4. Runtime topology

The agent runs a small set of cooperating long-lived services on the Dart event loop.
None of them block the UI isolate with synchronous work; all Win32 calls are short and
all file/network I/O is async.

```
┌──────────────────────────────────────────────────────────────┐
│ LifecycleController                                          │
│  starts/stops everything, owns pause/resume, handles exit    │
└───┬───────────────┬───────────────┬───────────────┬──────────┘
    │               │               │               │
┌───▼──────┐  ┌─────▼──────┐  ┌─────▼──────┐  ┌─────▼────────┐
│SyncService│ │Heartbeat   │  │QueueEngine │  │PrinterManager│
│(poll jobs)│ │Service     │  │(process)   │  │(discover/    │
│           │ │            │  │            │  │ status poll) │
└───┬───────┘ └─────┬──────┘  └─────┬──────┘  └─────┬────────┘
    │               │               │               │
    └───────┬───────┴───────┬───────┘               │
            │               │                       │
      ┌─────▼─────┐   ┌─────▼──────┐         ┌──────▼───────┐
      │PrintAgentApi│ │QueueRepository│      │PrinterService│
      │  (Dio)     │  │  (SQLite)   │        │ (Win32 FFI)  │
      └────────────┘  └─────────────┘        └──────────────┘
```

* **SyncService** — adaptive polling of the server queue. Fetches, claims, and inserts
  jobs into the local queue. Backs off when idle, backs off harder when offline.
* **HeartbeatService** — periodic `POST /agents/heartbeat` with printer inventory and
  queue counters. Doubles as the server's liveness signal.
* **QueueEngine** — a serial worker that drains the local queue: download → validate →
  resolve printer → print → report. Bounded concurrency (default 1 job per printer).
* **PrinterManager** — owns discovery, caches the printer list, polls printer status,
  resolves `printer_id` → concrete device, applies print profiles.
* **LifecycleController** — the only object that starts and stops the others; the tray
  menu and the UI both talk to it rather than to individual services.

---

## 5. Threading and performance

* Win32 spooler calls (`EnumPrinters`, `OpenPrinter`, `WritePrinter`) are non-blocking
  in practice (microseconds to a few ms) and run on the main isolate.
* Rendering and spooling a document is delegated to a **print strategy** which performs
  its file and process work with `await`; the UI never blocks.
* Long-running or CPU-heavy work (hashing large downloads, image transcode) runs in
  `Isolate.run`.
* All timers are cancellable and owned by `LifecycleController`; there are **no busy
  loops**. Idle polling backs off (see §7).
* Bounded growth is enforced everywhere: log files rotate by size and count, the job
  history table is pruned by age/row-count on a daily maintenance pass, in-memory
  streams are broadcast with no replay buffers.

---

## 6. Error and retry strategy

### Error taxonomy

All failures are normalised into `AppException` subclasses before leaving the data layer:

| Exception | Cause | Agent behaviour |
|---|---|---|
| `NetworkException` | timeout, DNS, socket, TLS | offline mode, retry with backoff |
| `AuthException` (401) | token invalid/expired | stop syncing, surface "re-pair required" |
| `ForbiddenException` (403) | agent disabled/revoked | stop syncing, surface message |
| `NotFoundException` (404) | job or endpoint gone | mark job cancelled locally, do not retry |
| `RateLimitException` (429) | server throttling | honour `Retry-After`, widen poll interval |
| `ServerException` (5xx) | plugin/server fault | retry with backoff |
| `DocumentException` | download/validation failure | fail job, retry per policy |
| `PrinterException` | device offline, spooler error | fail job, retry per policy, surface printer state |
| `StorageException` | SQLite failure | log, surface diagnostics |

Every exception carries a `userMessage` (plain language, safe to show) and a
`technicalDetail` (only ever written to logs). The UI renders `userMessage`; the log
renders both.

### Retry policy

`RetryPolicy` is a value object, configurable in Settings and persisted:

```
maxAttempts     default 4
delays          [10s, 30s, 2m]   (delay before attempt n+1)
backoff         exponential with jitter beyond the explicit list
retryOn         network, server, rate-limit, printer-unavailable, document
neverRetryOn    auth, forbidden, not-found, cancelled, validation
```

Failed jobs re-enter the queue with `next_attempt_at` set; the engine only picks up jobs
whose `next_attempt_at` has passed. After `maxAttempts` the job is terminal-failed,
reported to the server, and left visible in the queue for operator action.

---

## 7. Synchronisation model

Polling is configurable (`3s` default, plus 5/10/30/60s presets) and **adaptive**:

* Jobs found on the last poll → poll at the configured interval.
* `idleBackoffAfter` consecutive empty polls → interval grows geometrically up to
  `maxIdleInterval` (default 30s), which cuts idle API traffic by an order of magnitude.
* Any local event (manual refresh, tray "Sync now", job completion) resets to the fast
  interval immediately.
* Offline → interval grows to `offlineRetryInterval` (default 30s) and only a cheap
  reachability probe is issued.

`SyncService` is written against a `JobSource` interface. The polling implementation is
`PollingJobSource`; a future `WebSocketJobSource` can be substituted with no change to
the queue engine — this is why sync and queue processing are separate services.

---

## 8. Duplicate protection

Duplicate printing is treated as the most serious defect class. Four independent guards:

1. **Database uniqueness** — `print_jobs.server_job_id` has a `UNIQUE` index. Inserting
   an already-known job is an `INSERT OR IGNORE`, so a repeated server response can
   never create a second row.
2. **Terminal-state check before spooling** — `JobProcessor` re-reads the row inside a
   transaction immediately before handing bytes to the spooler and aborts if the status
   is already `completed`, `cancelled`, or `printing` with a live lease.
3. **Print lease** — a job transitioning to `printing` records `lease_owner`
   (a per-process UUID) and `lease_expires_at`. Only the lease owner may complete it.
   On startup a different `lease_owner` proves the process died mid-print.
4. **Idempotency key** — every state-changing API call sends
   `Idempotency-Key: <agent_id>:<server_job_id>:<action>` so a retried `complete` after
   a network timeout cannot be double-counted server-side.

### Crash recovery

On startup, jobs found in `printing` are **not** reprinted automatically. They move to
`interrupted` and the operator sees "This job was printing when the agent stopped —
did it print?" with **Mark as printed** / **Print again** actions. If the server exposes
a spool-verification result the agent uses it; otherwise the safe default is to ask.
`Settings → Printing → Recovery behaviour` allows an operator to change this to
"always reprint" or "always mark printed" for unattended sites.

---

## 9. Security posture

* Only HTTPS is accepted for store URLs (an explicit, per-install, logged opt-in exists
  for `http://` on local development hosts and is off by default).
* TLS certificate validation is **never** disabled. There is no code path that sets
  `badCertificateCallback` to accept invalid certificates.
* No WordPress username or password is ever requested, transmitted or stored. The agent
  pairs with a short-lived pairing code approved by an administrator in wp-admin.
* Tokens are stored encrypted with **Windows DPAPI** (`CryptProtectData`, user scope +
  an application entropy salt) and written to `%APPDATA%`. The plaintext token exists
  only in memory.
* Logs are redacted: tokens, `Authorization` headers, pairing codes and query secrets
  are replaced with `***` by a redaction filter before any sink sees them.
* Documents are only downloaded from the paired store's origin (or an explicit
  server-declared allow-list), over HTTPS, with a size cap, a content-type check, a
  magic-byte check, and an optional server-supplied SHA-256 verification.
* Downloaded files are never executed. They are opened by the print pipeline only.
* No secrets in source. There is no bundled API key.

See `SECURITY.md` for the full threat model.

---

## 10. Extensibility (designed for, not implemented now)

The following are deliberately anticipated by the interfaces:

* **Multiple stores** — `agents` and `stores` are separate tables with a foreign key;
  the API client is constructed per-store; `ActiveStore` is a single-valued provider
  today and becomes a list later.
* **Cloud print server / WebSocket** — `JobSource` interface (§7).
* **Printer groups and fallback** — `PrinterResolution` already returns a resolution
  *strategy* result, not just a printer; group and fallback resolvers are new
  implementations of `PrinterResolver`.
* **Vendor drivers / ESC-POS** — `PrintStrategy` interface with a registry keyed by
  capability; adding a raw ESC/POS or vendor strategy is an additive change.
* **Updates** — `UpdateService` interface with a no-op implementation shipped today.
* **Licensing, analytics, remote monitoring, teams** — the heartbeat payload and the
  agent record already carry a `metadata` map, and the API client has a versioned base
  path (`/wpm/v1/`) so new endpoints do not disturb existing ones.

---

## 11. Build and platform boundary

Windows-specific code is confined to:

* `lib/services/printer/win32/` — FFI bindings and the spooler wrapper.
* `lib/services/background/autostart_service.dart` — registry Run key.
* `lib/core/security/dpapi.dart` — DPAPI wrapper.

Each has an abstract contract in the domain layer and a `Platform.isWindows` guard plus
a portable fallback (`UnsupportedPrinterService`, `FileCredentialStore` with an explicit
"unencrypted" warning), so a macOS/Linux port means adding implementations rather than
restructuring. The Windows implementation is not compromised for portability.
