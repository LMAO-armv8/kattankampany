# Developer guide

A tour of the codebase, the conventions it holds itself to, and how to extend it
without unpicking the guarantees.

---

## 1. The five rules

These are the invariants the rest of the design depends on. Breaking one is a
bug even if the tests still pass.

1. **A document is never printed twice.** Every path to the spooler goes through
   `JobProcessor`, which re-checks state inside the transaction that transitions
   the row to `printing`. Duplicate protection is defence in depth: the UNIQUE
   index, the terminal-state check, the print lease, and the idempotency key.
2. **A printer is never silently substituted.** `PrinterResolver` returns
   `UnavailablePrinter` unless the *job* opted into fallback.
3. **A token never reaches disk unencrypted, a log, or the UI.** `Redaction`
   runs before any sink; `AgentCredentials.toString()` is deliberately opaque.
4. **A service never reads a Riverpod provider.** GetIt owns services, Riverpod
   projects them. This is what keeps the agent working with no window open.
5. **Nothing grows without bound.** Logs rotate, history is pruned, the
   documents folder is swept, polling backs off, and there are no busy loops.

---

## 2. Layering

```
presentation  →  domain  ←  data / services
     │                          │
     └──────→  core  ←──────────┘
```

* `core/` — infrastructure with no feature knowledge.
* `features/<name>/domain/` — immutable models and enums. Pure Dart.
* `features/<name>/presentation/` — widgets and Riverpod controllers.
* `services/` — concrete implementations: REST, SQLite, Win32, the queue engine.

A `services/` file may import `core/` and any `domain/`. It may **not** import
anything under `presentation/`.

---

## 3. State management

| Concern | Tool | Where |
|---|---|---|
| Long-lived services | GetIt | `lib/core/di/service_locator.dart` |
| Reactive UI state | Riverpod | `lib/core/di/providers.dart` |

Providers are thin: they read a service from `sl<T>()` and adapt its broadcast
stream. Two helpers do most of the work:

* `_seeded(initial, stream)` — emits the current value immediately, then updates.
* `_reload(trigger, load)` — re-runs an async read whenever the trigger fires,
  coalescing bursts.

Adding a screen usually means adding one provider of each shape, not a new
state-management pattern.

---

## 4. Where things live

| I want to… | Go to |
|---|---|
| Change an API path | `core/network/api_endpoints.dart` |
| Change how an HTTP error is presented | `core/network/api_exception_mapper.dart` |
| Add a database table | `core/storage/migrations.dart` (append a new `Migration`) |
| Change what is redacted from logs | `core/logging/redaction.dart` |
| Add a setting | `core/config/app_settings.dart` + a row in the Settings screen |
| Change printer discovery | `services/printer/win32/windows_spooler.dart` |
| Add a document format | `features/printing/domain/print_document.dart` + a strategy |
| Change the retry schedule | `core/utils/retry_policy.dart` (and the Settings preset list) |
| Change the job pipeline | `services/queue/job_processor.dart` |
| Change how work is fetched | `services/background/job_source.dart` |

---

## 5. Extending it

### Add a print strategy

1. Implement `PrintStrategy` in `services/printer/strategies/`.
2. Declare `type` (add an enum value to `PrintStrategyType` if it is new) and
   `autoSelectableFor`.
3. Register it in the `PrintStrategyRegistry` factory in `service_locator.dart`.

Registry order matters for `auto`: the first strategy that lists the document
type wins. Return an **empty** `autoSelectableFor` for anything that must be
requested explicitly — that is how ESC/POS avoids being sent to a laser printer.

### Add a document type

1. Add the enum value to `DocumentType` with its `@JsonValue`,
   `acceptedContentTypes`, `fileExtension` and label.
2. Add a magic-byte case to `DocumentType.sniff` if the format has a signature,
   and to `DocumentValidator._hasSignature`.
3. Provide a strategy that lists it in `autoSelectableFor`.

### Replace polling with a push transport

`SyncService` is written against `JobSource`. Implement it (a WebSocket, a cloud
relay), set `requiresPolling` to false, and pass it into `SyncService`. Nothing
in the queue engine or the UI changes — that separation is the whole reason
fetching and printing are different services.

### Support multiple stores

The schema is already multi-store: `stores` and `agents` are separate tables
with a foreign key, and `print_jobs.store_id` is part of the duplicate index.
The work is in `AgentSession` (one `PrintAgentApi` per store instead of one) and
in the UI (a store switcher). Nothing needs migrating.

### Ship a real updater

Implement `UpdateService` and register it in place of `NoopUpdateService`. The
contract in `update_service.dart` lists the non-negotiables: HTTPS with
validation on, verify a signature or checksum before touching a download, hand
off to the platform installer rather than executing a payload, and never apply
an update while a job is printing.

### Port to macOS or Linux

Windows-specific code is confined to four places, each behind an interface:

| File | Interface | Fallback already present |
|---|---|---|
| `services/printer/win32/` | `PrinterService` | `UnsupportedPrinterService` |
| `core/security/dpapi.dart` | `SecureCredentialStore` | `UnencryptedFileCredentialStore` (dev only) |
| `services/background/autostart_service.dart` | `AutostartService` | `NoopAutostartService` |
| `core/platform/single_instance.dart` | — | no-op off Windows |

Add a sibling implementation and select it in `service_locator.dart`.

---

## 6. Conventions

* **Errors.** The data layer never lets a `DioException`, `SqliteException` or a
  Win32 code escape. Map to an `AppException` subclass with a plain-language
  `userMessage` and a technical `technicalDetail`. The UI shows the former; the
  log gets both.
* **Logging.** Always pass a `LogCategory` and a structured `context` map rather
  than interpolating values into the message — the log viewer filters on both.
* **Async.** No blocking work on the UI isolate. Long CPU work goes in
  `Isolate.run`. Every `Timer` is owned and cancelled by
  `LifecycleController`.
* **Streams.** Service streams are broadcast with no replay buffer. Every
  subscription is stored and cancelled in `dispose()`.
* **Naming.** `printerKey` is always the Windows printer name — the stable
  identifier shared with the server. `serverJobId` is always the plugin's id.
  Local UUIDs are `id`.
* **No vendor names.** No printer model, carrier or store may appear in code,
  seed data or UI copy. `printer_test.dart` asserts this for seeded profiles.

---

## 7. Testing

```powershell
flutter test
flutter test test/unit/queue_persistence_test.dart   # one file
```

The tests use the **real** DAOs, the real queue repository, the real printer
manager and the real SQL, against an in-memory database. Only the hardware
(`FakePrinterService`), the network (`FakeHttpAdapter`) and two collaborators
(`FakeDocumentDownloader`, `FakeJobReporter`) are substituted. That is deliberate
— the duplicate-protection and recovery guarantees are properties of the SQL, so
mocking the database would test nothing.

| File | Covers |
|---|---|
| `retry_policy_test.dart` | Retry schedule, jitter bounds, non-retryable errors, backoff. |
| `security_test.dart` | URL normalisation, document origin gating, payload validation, log redaction. |
| `queue_persistence_test.dart` | Persistence, counters, archiving, duplicate prevention, leasing, restart recovery, failure handling. |
| `printer_test.dart` | Win32 status mapping, port classification, discovery and reconciliation, printer resolution and assignment. |
| `job_processor_test.dart` | The full pipeline: success, failure, retry ceiling, printer unavailable, fallback, duplicate suppression. |
| `api_test.dart` | Auth headers, registration, pairing, job mapping, claim conflicts, idempotency keys, HTTP error mapping. |
| `settings_and_offline_test.dart` | Settings round-trip and clamping, forward compatibility, offline behaviour, idempotency records. |
| `strategies_test.dart` | Strategy selection, page geometry, profile parsing, ESC/POS encoding, HTML degradation, filename safety. |

`TestEnvironment.create()` in `test/fakes/test_environment.dart` builds the whole
stack; use it rather than wiring DAOs by hand.

---

## 8. Debugging on a customer machine

1. **Diagnostics → Run diagnostics** — checks storage, credentials, network,
   API, authorisation, printers and renderers in that order, with a remedy on
   each failure. Tick *Include a test print* to prove the printer path.
2. **Diagnostics → View logs** — filter by level and category, then
   **Export logs** to produce a support bundle. Tokens are already redacted, so
   the file is safe to email.
3. `%APPDATA%\WooCommercePrintAgent\logs\agent.log` is the same content on disk.
4. Set **Settings → Logs → Log level** to `debug` to capture request/response
   lines, then set it back — debug logging is verbose.

Common findings:

| Symptom | Usually means |
|---|---|
| "Printer unavailable" on every job | The server's `printer_key` does not match the Windows printer name. Compare Diagnostics → Printers with the plugin's device list. |
| Jobs stuck in *Needs review* after a crash | Working as designed: the agent will not reprint something that may already be on paper. Resolve them on the Print queue screen, or change **Settings → After an unexpected shutdown**. |
| Offline despite a working browser | A proxy or firewall is blocking outbound HTTPS from the agent, or TLS interception is breaking certificate validation. |
| HTML jobs print as plain text | Microsoft Edge was not found, so the renderer degraded. Diagnostics reports this explicitly. |
