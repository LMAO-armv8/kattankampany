# Print pipeline, printer abstraction and strategies

## 1. Printer abstraction

```dart
abstract class PrinterService {
  Future<List<DiscoveredPrinter>> discover();
  Future<PrinterStatus> getStatus(String printerKey);
  Future<String?> getDefaultPrinterKey();
  Future<PrintResult> print(PrintRequest request);
  Future<void> cancel(String printerKey, int spoolerJobId);
  Future<PrintResult> testPrint(String printerKey, {PrintProfile? profile});
  Future<bool> isAvailable(String printerKey);
}
```

`WindowsPrinterService` is the shipped implementation. `UnsupportedPrinterService`
answers on non-Windows hosts so the app still runs (for development and for the future
macOS/Linux ports) without `Platform.isWindows` checks leaking into callers.

`PrinterManager` sits above `PrinterService` and adds the stateful parts: the cached
inventory, the status poll timer, persistence to SQLite, the discovery-change stream,
and printer resolution.

### Discovery scope and transports

Discovery calls `EnumPrintersW` with `PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS`,
so **every** printer the Windows spooler knows about is returned — USB, Bluetooth,
network, serial, parallel and virtual alike. Nothing is filtered out; virtual devices
(PDF writers, fax) are flagged rather than hidden, so an operator can still route
invoices to one deliberately. A printer that can be printed to from Windows is, by
definition, installed in the spooler, so this is the complete set of usable devices.

`EnumPrintersW` reports a port *name* but nothing about how that port is wired.
`PortInspector` (`lib/services/printer/win32/port_inspector.dart`) resolves the rest
from two read-only `HKEY_LOCAL_MACHINE` lookups — neither needs elevation:

| Case | Why the port name is not enough | Source |
|---|---|---|
| **Bluetooth** | Windows exposes a paired Bluetooth printer as a virtual serial port, so it arrives as `COM5`, indistinguishable from an RS-232 printer. | `HARDWARE\DEVICEMAP\SERIALCOMM`, where a Bluetooth link appears as `\Device\BthModem0`. |
| **Network** | A Standard TCP/IP port may be named anything its creator typed. | `…\Print\Monitors\Standard TCP/IP Port\Ports\<port>` → `HostName` / `IPAddress`. |

Classification order is port name → registry topology → driver/product name, and it
degrades to name-only when the registry is unreadable. It is advisory: it drives the
UI filter and the heartbeat inventory, and is never used to decide whether a printer
may be printed to.

> **Wi-Fi vs Ethernet is deliberately not distinguished.** Windows does not record it,
> and it is not discoverable from the host — a printer at `192.168.1.50` looks
> identical either way. Both are `PrinterConnectionType.network`, labelled
> *Wi-Fi / Network*. Splitting them would mean sending a guess to the server as fact.

### Resolution rules (spec §18/§19)

`PrinterResolver.resolve(job)` returns one of:

| Result | When | Job outcome |
|---|---|---|
| `Resolved(printer)` | requested `printer_key` exists and is available | print |
| `ResolvedByProfile(printer)` | no `printer_key`; a print profile maps the document kind to a printer | print |
| `ResolvedByDefault(printer)` | no `printer_key`, no profile mapping, and a local default printer is configured | print |
| `Fallback(printer, from:)` | requested printer missing **and** `allow_fallback == true` **and** a fallback printer is configured | print, logged loudly, reported in `metadata` |
| `Unavailable(reason)` | requested printer missing/offline and fallback not permitted | job fails with `printer_not_found` / `printer_offline`, surfaced as "Printer unavailable" |

The agent **never** silently substitutes a printer. `Fallback` requires the server to
have opted in per job.

## 2. Document abstraction

```dart
enum DocumentType { pdf, png, jpeg, html, text, raw }

class PrintDocument {
  final DocumentType type;
  final String? url;          // downloaded from the paired store only
  final Uint8List? inlineData; // base64 from the API
  final String? filename;
  final String? sha256;
  final int? sizeBytes;
  final DateTime? expiresAt;
}

class PrintRequest {
  final String jobId;
  final String printerKey;
  final PrintDocument document;
  final Uint8List data;       // resolved bytes (downloaded or inline)
  final PrintProfile profile; // paper, orientation, margins, scaling, copies, quality…
  final String documentTitle; // shown in the Windows spooler
}
```

## 3. Strategies

`PrintStrategy` decides *how* bytes reach the device. The registry picks one by
(`profile.strategy`, `document.type`, printer capabilities); `strategy: auto` resolves
by document type.

| Strategy | Handles | Mechanism |
|---|---|---|
| `PdfPrintStrategy` | `pdf` | PDFium render → GDI device context via the `printing` plugin, honouring page size, orientation, scaling, margins, copies. |
| `ImagePrintStrategy` | `png`, `jpeg` | Decode, apply scaling/orientation into a single-page PDF sized to the profile, then delegate to `PdfPrintStrategy`. |
| `TextPrintStrategy` | `text` | Lay out monospaced text into a PDF at the profile's page size, then delegate. |
| `HtmlPrintStrategy` | `html` | Renders via headless Microsoft Edge (`--headless=new --print-to-pdf`) when present, then delegates to PDF. If Edge is not found, degrades to `TextPrintStrategy` on the stripped text and logs a warning. |
| `RawPrintStrategy` | `raw` | `StartDocPrinter(datatype: RAW)` → `WritePrinter` → `EndDocPrinter`. Bytes pass through untouched. |
| `EscPosPrintStrategy` | `raw`, `png`, `text` when explicitly selected | Builds ESC/POS command streams (init, alignment, raster image `GS v 0`, cut) and sends them via the RAW path. **Never selected by `auto`** — a profile must ask for it, because most printers are not ESC/POS devices. |

Adding a vendor driver later means implementing `PrintStrategy` and registering it; no
existing code changes.

## 4. End-to-end job pipeline

```
 SyncService                          QueueEngine / JobProcessor
 ───────────                          ──────────────────────────
 1 GET /print-jobs
 2 POST /{id}/claim          ──► 409? drop, not an error
 3 INSERT OR IGNORE into print_jobs (status=claimed)
                                     4 pick ready job
                                       (status in {queued,claimed},
                                        next_attempt_at <= now,
                                        ordered by priority, created_at)
                                     5 duplicate guard: re-read row in txn;
                                       abort if completed/cancelled or leased
                                     6 acquire lease (owner=process uuid, +5 min)
                                     7 status=downloading
                                       ├ inline data? use it
                                       └ else GET document
                                          · origin must equal paired store
                                          · https only
                                          · size cap
                                          · content-type ↔ declared type
                                          · magic bytes ↔ content-type
                                          · sha256 if supplied
                                     8 resolve printer (§1) — Unavailable ⇒ fail
                                     9 check printer availability/status
                                    10 POST /{id}/start
                                    11 status=printing (persisted before spooling)
                                    12 strategy.print(request)
                                    13 verify: strategy returned ok AND
                                       spooler accepted the document
                                    14 status=completed, lease released
                                    15 POST /{id}/complete (idempotent)
                                    16 mark reported_at; temp file deleted
```

Failure at any step 7–13:

```
  a persist error_code/error_message/error_detail, attempt_count++
  b POST /{id}/fail with will_retry + next_attempt_at
  c if attempt_count < max_attempts → status=queued, next_attempt_at = now + delay
    else                            → status=failed (terminal, operator visible)
  d lease released, temp file deleted
```

Steps 15 and b are recorded in `idempotency_keys` *before* the call and confirmed after,
so a crash between "printed" and "reported" replays the report — never the print.

## 5. Concurrency

The engine runs one worker per enabled printer (default), so a slow label printer does
not block invoices on a laser printer. Each worker holds at most one in-flight job, and
`_inFlightJobIds` prevents the same row being picked twice within the process. Workers
are cooperative `Future` loops driven by a single ticker, not threads, and they yield on
every `await`, so the UI stays at frame rate while printing.

## 6. What "print succeeded" means

The agent reports success when the Windows spooler has **accepted and closed the
document** (`EndDocPrinter` returned true, or the `printing` plugin's direct-print call
returned true) and the returned spool job id, if any, did not enter an error state within
a short verification window. This is the strongest guarantee available without
per-vendor status protocols; the limitation is documented for support staff, because a
printer that runs out of paper *after* the spooler accepted the document will report
success and require operator attention. Printer status polling surfaces that condition
on the Printers screen.
