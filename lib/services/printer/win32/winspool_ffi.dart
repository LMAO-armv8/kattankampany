// ignore_for_file: camel_case_types, non_constant_identifier_names
// ignore_for_file: library_private_types_in_public_api
//
// The `library_private_types_in_public_api` waiver is deliberate: the signature
// typedefs are an implementation detail of the binding and callers only ever
// invoke the resolved functions, never name their types.
//
// Hand-written FFI bindings for the Windows print spooler (winspool.drv).
//
// These are written out explicitly rather than taken from a generated binding
// package so that the struct layouts and calling conventions this application
// depends on are pinned in-tree and cannot drift with a dependency upgrade.
// Everything here mirrors the documented Win32 API exactly; see
// https://learn.microsoft.com/windows/win32/printdocs/printing-and-print-spooler-functions
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

/// `PRINTER_INFO_2W` — the level-2 printer record returned by `EnumPrintersW`
/// and `GetPrinterW`. Carries name, port, driver and the status bit field.
final class PRINTER_INFO_2W extends Struct {
  external Pointer<Utf16> pServerName;
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pShareName;
  external Pointer<Utf16> pPortName;
  external Pointer<Utf16> pDriverName;
  external Pointer<Utf16> pComment;
  external Pointer<Utf16> pLocation;
  external Pointer<Void> pDevMode;
  external Pointer<Utf16> pSepFile;
  external Pointer<Utf16> pPrintProcessor;
  external Pointer<Utf16> pDatatype;
  external Pointer<Utf16> pParameters;
  external Pointer<Void> pSecurityDescriptor;

  @Uint32()
  external int Attributes;
  @Uint32()
  external int Priority;
  @Uint32()
  external int DefaultPriority;
  @Uint32()
  external int StartTime;
  @Uint32()
  external int UntilTime;
  @Uint32()
  external int Status;
  @Uint32()
  external int cJobs;
  @Uint32()
  external int AveragePPM;
}

/// `PRINTER_INFO_6` — just the status word. Cheaper than level 2 for polling.
final class PRINTER_INFO_6 extends Struct {
  @Uint32()
  external int dwStatus;
}

/// `DOC_INFO_1W` — describes the document being spooled.
final class DOC_INFO_1W extends Struct {
  external Pointer<Utf16> pDocName;

  /// Null to print to the device; a file path to spool to a file.
  external Pointer<Utf16> pOutputFile;

  /// `RAW` passes bytes through untouched; `TEXT` asks the spooler to render.
  external Pointer<Utf16> pDatatype;
}

/// `PRINTER_DEFAULTSW` — access rights requested by `OpenPrinterW`.
final class PRINTER_DEFAULTSW extends Struct {
  external Pointer<Utf16> pDatatype;
  external Pointer<Void> pDevMode;
  @Uint32()
  external int DesiredAccess;
}

/// `JOB_INFO_1W` — one entry of a printer's spool queue.
final class JOB_INFO_1W extends Struct {
  @Uint32()
  external int JobId;
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pMachineName;
  external Pointer<Utf16> pUserName;
  external Pointer<Utf16> pDocument;
  external Pointer<Utf16> pDatatype;
  external Pointer<Utf16> pStatus;
  @Uint32()
  external int Status;
  @Uint32()
  external int Priority;
  @Uint32()
  external int Position;
  @Uint32()
  external int TotalPages;
  @Uint32()
  external int PagesPrinted;
  // SYSTEMTIME Submitted — 8 × WORD. Not needed; declared so the struct size
  // matches the C definition when the spooler writes into our buffer.
  @Uint16()
  external int wYear;
  @Uint16()
  external int wMonth;
  @Uint16()
  external int wDayOfWeek;
  @Uint16()
  external int wDay;
  @Uint16()
  external int wHour;
  @Uint16()
  external int wMinute;
  @Uint16()
  external int wSecond;
  @Uint16()
  external int wMilliseconds;
}

// ---------------------------------------------------------------------------
// Native function typedefs
// ---------------------------------------------------------------------------

typedef _EnumPrintersNative = Int32 Function(
  Uint32 flags,
  Pointer<Utf16> name,
  Uint32 level,
  Pointer<Uint8> printerEnum,
  Uint32 cbBuf,
  Pointer<Uint32> pcbNeeded,
  Pointer<Uint32> pcReturned,
);
typedef _EnumPrintersDart = int Function(
  int flags,
  Pointer<Utf16> name,
  int level,
  Pointer<Uint8> printerEnum,
  int cbBuf,
  Pointer<Uint32> pcbNeeded,
  Pointer<Uint32> pcReturned,
);

typedef _OpenPrinterNative = Int32 Function(
  Pointer<Utf16> printerName,
  Pointer<IntPtr> phPrinter,
  Pointer<PRINTER_DEFAULTSW> pDefault,
);
typedef _OpenPrinterDart = int Function(
  Pointer<Utf16> printerName,
  Pointer<IntPtr> phPrinter,
  Pointer<PRINTER_DEFAULTSW> pDefault,
);

typedef _ClosePrinterNative = Int32 Function(IntPtr hPrinter);
typedef _ClosePrinterDart = int Function(int hPrinter);

typedef _GetPrinterNative = Int32 Function(
  IntPtr hPrinter,
  Uint32 level,
  Pointer<Uint8> pPrinter,
  Uint32 cbBuf,
  Pointer<Uint32> pcbNeeded,
);
typedef _GetPrinterDart = int Function(
  int hPrinter,
  int level,
  Pointer<Uint8> pPrinter,
  int cbBuf,
  Pointer<Uint32> pcbNeeded,
);

typedef _StartDocPrinterNative = Uint32 Function(
  IntPtr hPrinter,
  Uint32 level,
  Pointer<Uint8> pDocInfo,
);
typedef _StartDocPrinterDart = int Function(
  int hPrinter,
  int level,
  Pointer<Uint8> pDocInfo,
);

typedef _HandleOnlyNative = Int32 Function(IntPtr hPrinter);
typedef _HandleOnlyDart = int Function(int hPrinter);

typedef _WritePrinterNative = Int32 Function(
  IntPtr hPrinter,
  Pointer<Uint8> pBuf,
  Uint32 cbBuf,
  Pointer<Uint32> pcWritten,
);
typedef _WritePrinterDart = int Function(
  int hPrinter,
  Pointer<Uint8> pBuf,
  int cbBuf,
  Pointer<Uint32> pcWritten,
);

typedef _GetDefaultPrinterNative = Int32 Function(
  Pointer<Utf16> pszBuffer,
  Pointer<Uint32> pcchBuffer,
);
typedef _GetDefaultPrinterDart = int Function(
  Pointer<Utf16> pszBuffer,
  Pointer<Uint32> pcchBuffer,
);

typedef _SetJobNative = Int32 Function(
  IntPtr hPrinter,
  Uint32 jobId,
  Uint32 level,
  Pointer<Uint8> pJob,
  Uint32 command,
);
typedef _SetJobDart = int Function(
  int hPrinter,
  int jobId,
  int level,
  Pointer<Uint8> pJob,
  int command,
);

typedef _EnumJobsNative = Int32 Function(
  IntPtr hPrinter,
  Uint32 firstJob,
  Uint32 noJobs,
  Uint32 level,
  Pointer<Uint8> pJob,
  Uint32 cbBuf,
  Pointer<Uint32> pcbNeeded,
  Pointer<Uint32> pcReturned,
);
typedef _EnumJobsDart = int Function(
  int hPrinter,
  int firstJob,
  int noJobs,
  int level,
  Pointer<Uint8> pJob,
  int cbBuf,
  Pointer<Uint32> pcbNeeded,
  Pointer<Uint32> pcReturned,
);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// Lazily-resolved entry points. Constructing this on a non-Windows host throws,
/// so callers must guard with `Platform.isWindows` (see [WindowsPrinterService]).
class Winspool {
  Winspool._(this._winspool, this._kernel32);

  static Winspool? _instance;

  static Winspool get instance =>
      _instance ??= Winspool._(
        DynamicLibrary.open('winspool.drv'),
        DynamicLibrary.open('kernel32.dll'),
      );

  final DynamicLibrary _winspool;
  final DynamicLibrary _kernel32;

  late final _EnumPrintersDart enumPrinters =
      _winspool.lookupFunction<_EnumPrintersNative, _EnumPrintersDart>(
    'EnumPrintersW',
  );

  late final _OpenPrinterDart openPrinter =
      _winspool.lookupFunction<_OpenPrinterNative, _OpenPrinterDart>(
    'OpenPrinterW',
  );

  late final _ClosePrinterDart closePrinter =
      _winspool.lookupFunction<_ClosePrinterNative, _ClosePrinterDart>(
    'ClosePrinter',
  );

  late final _GetPrinterDart getPrinter =
      _winspool.lookupFunction<_GetPrinterNative, _GetPrinterDart>(
    'GetPrinterW',
  );

  late final _StartDocPrinterDart startDocPrinter =
      _winspool.lookupFunction<_StartDocPrinterNative, _StartDocPrinterDart>(
    'StartDocPrinterW',
  );

  late final _HandleOnlyDart startPagePrinter =
      _winspool.lookupFunction<_HandleOnlyNative, _HandleOnlyDart>(
    'StartPagePrinter',
  );

  late final _HandleOnlyDart endPagePrinter =
      _winspool.lookupFunction<_HandleOnlyNative, _HandleOnlyDart>(
    'EndPagePrinter',
  );

  late final _HandleOnlyDart endDocPrinter =
      _winspool.lookupFunction<_HandleOnlyNative, _HandleOnlyDart>(
    'EndDocPrinter',
  );

  late final _WritePrinterDart writePrinter =
      _winspool.lookupFunction<_WritePrinterNative, _WritePrinterDart>(
    'WritePrinter',
  );

  late final _GetDefaultPrinterDart getDefaultPrinter = _winspool
      .lookupFunction<_GetDefaultPrinterNative, _GetDefaultPrinterDart>(
    'GetDefaultPrinterW',
  );

  late final _SetJobDart setJob =
      _winspool.lookupFunction<_SetJobNative, _SetJobDart>('SetJobW');

  late final _EnumJobsDart enumJobs =
      _winspool.lookupFunction<_EnumJobsNative, _EnumJobsDart>('EnumJobsW');

  late final _GetLastErrorDart getLastError =
      _kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
    'GetLastError',
  );
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

abstract final class PrinterEnumFlags {
  static const int local = 0x00000002;
  static const int connections = 0x00000004;
  static const int name = 0x00000008;

  /// Local devices plus printers connected from a print server — what an
  /// operator sees in the Windows "Printers & scanners" list.
  static const int localAndConnections = local | connections;
}

abstract final class PrinterStatusFlags {
  static const int paused = 0x00000001;
  static const int error = 0x00000002;
  static const int pendingDeletion = 0x00000004;
  static const int paperJam = 0x00000008;
  static const int paperOut = 0x00000010;
  static const int manualFeed = 0x00000020;
  static const int paperProblem = 0x00000040;
  static const int offline = 0x00000080;
  static const int ioActive = 0x00000100;
  static const int busy = 0x00000200;
  static const int printing = 0x00000400;
  static const int outputBinFull = 0x00000800;
  static const int notAvailable = 0x00001000;
  static const int waiting = 0x00002000;
  static const int processing = 0x00004000;
  static const int initializing = 0x00008000;
  static const int warmingUp = 0x00010000;
  static const int tonerLow = 0x00020000;
  static const int noToner = 0x00040000;
  static const int pagePunt = 0x00080000;
  static const int userIntervention = 0x00100000;
  static const int outOfMemory = 0x00200000;
  static const int doorOpen = 0x00400000;
  static const int serverUnknown = 0x00800000;
  static const int powerSave = 0x01000000;
}

abstract final class PrinterAttributeFlags {
  static const int queued = 0x00000001;
  static const int direct = 0x00000002;
  static const int isDefault = 0x00000004;
  static const int shared = 0x00000008;
  static const int network = 0x00000010;
  static const int hidden = 0x00000020;
  static const int local = 0x00000040;
  static const int workOffline = 0x00000400;
  static const int published = 0x00002000;
}

abstract final class PrinterAccessRights {
  static const int standardRightsRequired = 0x000F0000;
  static const int printerAccessAdminister = 0x00000004;
  static const int printerAccessUse = 0x00000008;

  /// Enough to submit and manage our own jobs, without demanding admin rights.
  static const int printerAccessUseOnly = printerAccessUse;
}

abstract final class JobControl {
  static const int pause = 1;
  static const int resume = 2;
  static const int cancel = 3;
  static const int restart = 4;
  static const int delete = 5;
}

abstract final class Win32ErrorCodes {
  static const int success = 0;
  static const int fileNotFound = 2;
  static const int accessDenied = 5;
  static const int invalidHandle = 6;
  static const int invalidParameter = 87;
  static const int insufficientBuffer = 122;
  static const int alreadyExists = 183;
  static const int invalidPrinterName = 1801;
  static const int printerNotFound = 3012;

  static String describe(int code) => switch (code) {
        success => 'Success',
        fileNotFound => 'Not found',
        accessDenied => 'Access denied',
        invalidHandle => 'Invalid handle',
        invalidParameter => 'Invalid parameter',
        insufficientBuffer => 'Insufficient buffer',
        alreadyExists => 'Already exists',
        invalidPrinterName => 'Invalid printer name',
        printerNotFound => 'Printer not found',
        _ => 'Win32 error $code',
      };
}
