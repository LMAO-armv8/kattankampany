import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/errors/error_codes.dart';
import '../../../features/printers/domain/printer_device.dart';
import '../../../features/printers/domain/printer_status.dart';
import 'winspool_ffi.dart';

/// Thin, allocation-safe wrapper over the Windows print spooler.
///
/// Every method here is short and synchronous — spooler calls return in
/// microseconds — and every allocation is released in a `finally`. Nothing in
/// this class knows about jobs, documents or the queue.
class WindowsSpooler {
  WindowsSpooler({Winspool? bindings}) : _bindings = bindings;

  final Winspool? _bindings;

  Winspool get _spool => _bindings ?? Winspool.instance;

  static bool get isSupported => Platform.isWindows;

  // -------------------------------------------------------------------------
  // Discovery
  // -------------------------------------------------------------------------

  /// Enumerates printers with `EnumPrintersW` at level 2.
  ///
  /// Level 2 is used (rather than the cheaper level 4) because it returns the
  /// port, driver and status in the same call, which is what the agent needs to
  /// report a useful inventory in its heartbeat.
  List<DiscoveredPrinter> enumeratePrinters() {
    if (!isSupported) return const <DiscoveredPrinter>[];

    final needed = calloc<Uint32>();
    final returned = calloc<Uint32>();
    Pointer<Uint8> buffer = nullptr;

    try {
      // First call sizes the buffer; it is expected to fail with
      // ERROR_INSUFFICIENT_BUFFER.
      _spool.enumPrinters(
        PrinterEnumFlags.localAndConnections,
        nullptr,
        2,
        nullptr,
        0,
        needed,
        returned,
      );

      final size = needed.value;
      if (size == 0) return const <DiscoveredPrinter>[];

      buffer = calloc<Uint8>(size);
      final ok = _spool.enumPrinters(
        PrinterEnumFlags.localAndConnections,
        nullptr,
        2,
        buffer,
        size,
        needed,
        returned,
      );
      if (ok == 0) {
        throw _lastErrorException('EnumPrintersW');
      }

      final count = returned.value;
      final stride = sizeOf<PRINTER_INFO_2W>();
      final base = buffer.cast<PRINTER_INFO_2W>();
      final results = <DiscoveredPrinter>[];
      final defaultKey = defaultPrinterName();

      for (var i = 0; i < count; i++) {
        final info = Pointer<PRINTER_INFO_2W>.fromAddress(
          base.address + i * stride,
        ).ref;

        final name = _readUtf16(info.pPrinterName);
        if (name == null || name.isEmpty) continue;

        final driver = _readUtf16(info.pDriverName);
        final port = _readUtf16(info.pPortName);
        final attributes = info.Attributes;
        final isVirtual = _looksVirtual(port, driver);

        results.add(
          DiscoveredPrinter(
            printerKey: name,
            displayName: name,
            driverName: driver,
            portName: port,
            manufacturer: _guessManufacturer(driver, name),
            model: _guessModel(driver, name),
            isDefault: defaultKey != null && defaultKey == name,
            state: mapStatus(
              info.Status,
              attributes: attributes,
              queuedJobs: info.cJobs,
            ),
            rawStatusBits: info.Status,
            queuedJobCount: info.cJobs,
            isVirtual: isVirtual,
          ),
        );
      }
      return results;
    } finally {
      calloc.free(needed);
      calloc.free(returned);
      if (buffer != nullptr) calloc.free(buffer);
    }
  }

  /// `GetDefaultPrinterW`. Returns null when the user has no default printer.
  String? defaultPrinterName() {
    if (!isSupported) return null;
    final size = calloc<Uint32>();
    Pointer<Utf16> buffer = nullptr;
    try {
      _spool.getDefaultPrinter(nullptr, size);
      final chars = size.value;
      if (chars == 0) return null;
      buffer = calloc<Uint16>(chars).cast<Utf16>();
      final ok = _spool.getDefaultPrinter(buffer, size);
      if (ok == 0) return null;
      return buffer.toDartString();
    } catch (_) {
      return null;
    } finally {
      calloc.free(size);
      if (buffer != nullptr) calloc.free(buffer);
    }
  }

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------

  /// Reads `PRINTER_INFO_2.Status` for one device.
  PrinterStatusReading readStatus(String printerKey) {
    if (!isSupported) return PrinterStatusReading.unknownFor(printerKey);

    final handle = calloc<IntPtr>();
    final namePtr = printerKey.toNativeUtf16();
    final needed = calloc<Uint32>();
    Pointer<Uint8> buffer = nullptr;

    try {
      if (_spool.openPrinter(namePtr, handle, nullptr) == 0) {
        // A printer that cannot be opened has been removed or is unreachable.
        return PrinterStatusReading(
          printerKey: printerKey,
          state: PrinterState.offline,
          readAt: DateTime.now(),
          detail: Win32ErrorCodes.describe(_spool.getLastError()),
        );
      }

      final hPrinter = handle.value;
      try {
        _spool.getPrinter(hPrinter, 2, nullptr, 0, needed);
        final size = needed.value;
        if (size == 0) return PrinterStatusReading.unknownFor(printerKey);

        buffer = calloc<Uint8>(size);
        if (_spool.getPrinter(hPrinter, 2, buffer, size, needed) == 0) {
          return PrinterStatusReading.unknownFor(printerKey);
        }

        final info = buffer.cast<PRINTER_INFO_2W>().ref;
        return PrinterStatusReading(
          printerKey: printerKey,
          state: mapStatus(
            info.Status,
            attributes: info.Attributes,
            queuedJobs: info.cJobs,
          ),
          readAt: DateTime.now(),
          rawStatusBits: info.Status,
          queuedJobCount: info.cJobs,
        );
      } finally {
        _spool.closePrinter(hPrinter);
      }
    } catch (_) {
      return PrinterStatusReading.unknownFor(printerKey);
    } finally {
      calloc.free(handle);
      calloc.free(namePtr);
      calloc.free(needed);
      if (buffer != nullptr) calloc.free(buffer);
    }
  }

  /// Maps the Win32 status bit field onto the agent's normalised states.
  ///
  /// Order matters: the most actionable condition wins, because that is what an
  /// operator needs to see first.
  static PrinterState mapStatus(
    int status, {
    int attributes = 0,
    int queuedJobs = 0,
  }) {
    bool has(int flag) => (status & flag) != 0;

    if (has(PrinterStatusFlags.offline) ||
        has(PrinterStatusFlags.notAvailable) ||
        (attributes & PrinterAttributeFlags.workOffline) != 0) {
      return PrinterState.offline;
    }
    if (has(PrinterStatusFlags.paperJam)) return PrinterState.paperJam;
    if (has(PrinterStatusFlags.paperOut) ||
        has(PrinterStatusFlags.paperProblem)) {
      return PrinterState.outOfPaper;
    }
    if (has(PrinterStatusFlags.doorOpen)) return PrinterState.doorOpen;
    if (has(PrinterStatusFlags.error) ||
        has(PrinterStatusFlags.userIntervention) ||
        has(PrinterStatusFlags.outOfMemory) ||
        has(PrinterStatusFlags.noToner)) {
      return PrinterState.error;
    }
    if (has(PrinterStatusFlags.paused)) return PrinterState.paused;
    if (has(PrinterStatusFlags.tonerLow)) return PrinterState.tonerLow;
    if (has(PrinterStatusFlags.printing) ||
        has(PrinterStatusFlags.busy) ||
        has(PrinterStatusFlags.processing) ||
        has(PrinterStatusFlags.ioActive) ||
        queuedJobs > 0) {
      return PrinterState.busy;
    }
    // A status word of 0 means "no conditions reported", which is the normal
    // idle state for most drivers.
    if (status == 0) return PrinterState.ready;
    return PrinterState.ready;
  }

  // -------------------------------------------------------------------------
  // RAW printing
  // -------------------------------------------------------------------------

  /// Sends [data] to [printerKey] using the RAW datatype — the bytes reach the
  /// device untouched. Used for ESC/POS, ZPL, PCL and anything else the caller
  /// has already rendered into printer language.
  ///
  /// Returns the spool job id.
  int printRaw({
    required String printerKey,
    required Uint8List data,
    required String documentTitle,
    String datatype = 'RAW',
  }) {
    if (!isSupported) {
      throw const PrinterException(
        userMessage: 'Printing is only available on Windows.',
        code: ErrorCodes.printerError,
        retryable: false,
      );
    }
    if (data.isEmpty) {
      throw const PrinterException(
        userMessage: 'The document contained no data to print.',
        code: ErrorCodes.documentInvalid,
        retryable: false,
      );
    }

    final handle = calloc<IntPtr>();
    final namePtr = printerKey.toNativeUtf16();
    final docNamePtr = documentTitle.toNativeUtf16();
    final datatypePtr = datatype.toNativeUtf16();
    final docInfo = calloc<DOC_INFO_1W>();
    final written = calloc<Uint32>();
    final defaults = calloc<PRINTER_DEFAULTSW>();
    Pointer<Uint8> payload = nullptr;

    try {
      defaults.ref.pDatatype = datatypePtr;
      defaults.ref.pDevMode = nullptr;
      defaults.ref.DesiredAccess = PrinterAccessRights.printerAccessUse;

      if (_spool.openPrinter(namePtr, handle, defaults) == 0) {
        throw _lastErrorException(
          'OpenPrinterW',
          printerKey: printerKey,
          userMessage:
              'The printer "$printerKey" could not be opened. It may have been '
              'removed or renamed.',
          code: ErrorCodes.printerNotFound,
        );
      }

      final hPrinter = handle.value;
      var docStarted = false;
      var pageStarted = false;

      try {
        docInfo.ref.pDocName = docNamePtr;
        docInfo.ref.pOutputFile = nullptr;
        docInfo.ref.pDatatype = datatypePtr;

        final jobId =
            _spool.startDocPrinter(hPrinter, 1, docInfo.cast<Uint8>());
        if (jobId == 0) {
          throw _lastErrorException(
            'StartDocPrinterW',
            printerKey: printerKey,
            userMessage: 'The printer would not accept a new document.',
            code: ErrorCodes.spoolerError,
          );
        }
        docStarted = true;

        if (_spool.startPagePrinter(hPrinter) == 0) {
          throw _lastErrorException(
            'StartPagePrinter',
            printerKey: printerKey,
            userMessage: 'The printer would not accept the page.',
            code: ErrorCodes.spoolerError,
          );
        }
        pageStarted = true;

        payload = calloc<Uint8>(data.length);
        payload.asTypedList(data.length).setAll(0, data);

        if (_spool.writePrinter(hPrinter, payload, data.length, written) == 0) {
          throw _lastErrorException(
            'WritePrinter',
            printerKey: printerKey,
            userMessage: 'The document could not be sent to the printer.',
            code: ErrorCodes.spoolerError,
          );
        }
        if (written.value != data.length) {
          throw PrinterException(
            userMessage: 'The printer accepted only part of the document.',
            code: ErrorCodes.spoolerError,
            technicalDetail:
                'WritePrinter wrote ${written.value} of ${data.length} bytes.',
            printerKey: printerKey,
          );
        }

        pageStarted = false;
        if (_spool.endPagePrinter(hPrinter) == 0) {
          throw _lastErrorException(
            'EndPagePrinter',
            printerKey: printerKey,
            userMessage: 'The printer did not finish the page.',
            code: ErrorCodes.spoolerError,
          );
        }

        docStarted = false;
        if (_spool.endDocPrinter(hPrinter) == 0) {
          throw _lastErrorException(
            'EndDocPrinter',
            printerKey: printerKey,
            userMessage: 'The printer did not finish the document.',
            code: ErrorCodes.spoolerError,
          );
        }

        return jobId;
      } catch (_) {
        // Unwind a partially-started document so the spooler does not keep a
        // half-open job that blocks the queue.
        if (pageStarted) {
          try {
            _spool.endPagePrinter(hPrinter);
          } catch (_) {/* best effort */}
        }
        if (docStarted) {
          try {
            _spool.endDocPrinter(hPrinter);
          } catch (_) {/* best effort */}
        }
        rethrow;
      } finally {
        _spool.closePrinter(hPrinter);
      }
    } finally {
      calloc.free(handle);
      calloc.free(namePtr);
      calloc.free(docNamePtr);
      calloc.free(datatypePtr);
      calloc.free(docInfo);
      calloc.free(written);
      calloc.free(defaults);
      if (payload != nullptr) calloc.free(payload);
    }
  }

  // -------------------------------------------------------------------------
  // Job control
  // -------------------------------------------------------------------------

  bool cancelJob(String printerKey, int spoolerJobId) {
    if (!isSupported) return false;
    final handle = calloc<IntPtr>();
    final namePtr = printerKey.toNativeUtf16();
    try {
      if (_spool.openPrinter(namePtr, handle, nullptr) == 0) return false;
      final hPrinter = handle.value;
      try {
        return _spool.setJob(
              hPrinter,
              spoolerJobId,
              0,
              nullptr,
              JobControl.cancel,
            ) !=
            0;
      } finally {
        _spool.closePrinter(hPrinter);
      }
    } catch (_) {
      return false;
    } finally {
      calloc.free(handle);
      calloc.free(namePtr);
    }
  }

  /// Number of jobs currently sitting in a printer's Windows spool queue.
  int queuedJobCount(String printerKey) =>
      readStatus(printerKey).queuedJobCount;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  PrinterException _lastErrorException(
    String call, {
    String? printerKey,
    String userMessage = 'The printer reported an error.',
    String code = ErrorCodes.printerError,
  }) {
    final error = _spool.getLastError();
    return PrinterException(
      userMessage: userMessage,
      code: code,
      technicalDetail: '$call failed: ${Win32ErrorCodes.describe(error)} '
          '(GetLastError=$error)',
      printerKey: printerKey,
      retryable: error != Win32ErrorCodes.invalidPrinterName,
    );
  }

  static String? _readUtf16(Pointer<Utf16> pointer) {
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } catch (_) {
      return null;
    }
  }

  /// Windows exposes no vendor field, so the driver name is the only hint.
  /// This is display metadata only — nothing branches on it, and no printer
  /// model is special-cased anywhere in the application.
  static String? _guessManufacturer(String? driver, String name) {
    final source = (driver?.isNotEmpty ?? false) ? driver! : name;
    final token = source.trim().split(RegExp(r'[\s/]+')).firstOrNull;
    if (token == null || token.isEmpty) return null;
    if (token.length < 2) return null;
    return token;
  }

  static String? _guessModel(String? driver, String name) {
    final source = (driver?.isNotEmpty ?? false) ? driver! : name;
    final parts = source.trim().split(RegExp(r'[\s/]+'));
    if (parts.length < 2) return null;
    return parts.sublist(1).join(' ');
  }

  /// Virtual devices (print-to-file, PDF writers, fax) are still offered — an
  /// operator may legitimately route invoices to one — but they are labelled so
  /// nobody assigns shipping labels to a PDF writer by accident.
  static bool _looksVirtual(String? port, String? driver) {
    final haystack = '${port ?? ''} ${driver ?? ''}'.toUpperCase();
    return haystack.contains('PORTPROMPT') ||
        haystack.contains('NUL:') ||
        haystack.contains('SHRFAX') ||
        haystack.contains('MICROSOFT PRINT TO PDF') ||
        haystack.contains('MICROSOFT XPS') ||
        haystack.contains('ONENOTE');
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : this[0];
}
