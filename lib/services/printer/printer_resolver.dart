import '../../core/config/app_settings.dart';
import '../../core/errors/error_codes.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printers/domain/printer_status.dart';

/// The outcome of deciding which device a job should print on.
///
/// Modelled as a result type rather than a nullable printer so that *why* a
/// printer was chosen survives to the log and the UI — "printed to the fallback
/// device" is a materially different event from "printed to the requested one".
sealed class PrinterResolution {
  const PrinterResolution();

  PrinterDevice? get printer => switch (this) {
        ResolvedPrinter(:final device) => device,
        FallbackPrinter(:final device) => device,
        UnavailablePrinter() => null,
      };

  bool get isResolved => this is! UnavailablePrinter;
}

enum PrinterResolutionSource {
  /// The server named this printer and it was available.
  requested,

  /// A local print profile mapped the document to this printer.
  profile,

  /// No instruction — the configured default printer was used.
  agentDefault,

  /// No instruction and no configured default — the Windows default was used.
  windowsDefault,
}

final class ResolvedPrinter extends PrinterResolution {
  const ResolvedPrinter(this.device, this.source);

  final PrinterDevice device;
  final PrinterResolutionSource source;
}

/// The requested printer was unavailable and the **job** permitted a fallback.
/// Never produced unless `allow_fallback` was set on the job by the server.
final class FallbackPrinter extends PrinterResolution {
  const FallbackPrinter({
    required this.device,
    required this.requestedKey,
  });

  final PrinterDevice device;
  final String requestedKey;
}

final class UnavailablePrinter extends PrinterResolution {
  const UnavailablePrinter({
    required this.errorCode,
    required this.message,
    this.requestedKey,
  });

  final String errorCode;
  final String message;
  final String? requestedKey;
}

/// Decides which device a job prints on.
///
/// The governing rule (spec §18): the agent never silently substitutes a
/// printer. If the server named a device and that device is not usable, the job
/// fails visibly unless the job itself opted into fallback.
class PrinterResolver {
  const PrinterResolver();

  PrinterResolution resolve({
    required PrintJob job,
    required List<PrinterDevice> printers,
    required AppSettings settings,
    String? windowsDefaultKey,
  }) {
    PrinterDevice? find(String? key) {
      if (key == null || key.isEmpty) return null;
      for (final printer in printers) {
        if (printer.printerKey == key) return printer;
      }
      return null;
    }

    final requestedKey = job.requestedPrinterKey;

    // 1 — the server named a printer.
    if (requestedKey != null && requestedKey.isNotEmpty) {
      final requested = find(requestedKey);
      if (requested != null && requested.canAcceptJobs) {
        return ResolvedPrinter(requested, PrinterResolutionSource.requested);
      }

      final reason = requested == null
          ? _notFound(requestedKey)
          : _notUsable(requested);

      if (!job.allowFallback) return reason;

      final fallback = find(settings.fallbackPrinterKey) ??
          find(settings.defaultPrinterKey);
      if (fallback != null && fallback.canAcceptJobs) {
        return FallbackPrinter(device: fallback, requestedKey: requestedKey);
      }
      return reason;
    }

    // 2 — the agent's configured default.
    final configuredDefault = find(settings.defaultPrinterKey);
    if (configuredDefault != null && configuredDefault.canAcceptJobs) {
      return ResolvedPrinter(
        configuredDefault,
        PrinterResolutionSource.agentDefault,
      );
    }

    // 3 — the Windows default, if the agent has it enabled.
    final windowsDefault = find(windowsDefaultKey) ??
        printers.where((PrinterDevice p) => p.isDefault).firstOrNull;
    if (windowsDefault != null && windowsDefault.canAcceptJobs) {
      return ResolvedPrinter(
        windowsDefault,
        PrinterResolutionSource.windowsDefault,
      );
    }

    // 4 — nothing usable.
    if (configuredDefault != null) return _notUsable(configuredDefault);
    return const UnavailablePrinter(
      errorCode: ErrorCodes.printerNotFound,
      message: 'No printer is available. Choose a default printer in Settings, '
          'or assign a printer to this document in your store.',
    );
  }

  static UnavailablePrinter _notFound(String key) => UnavailablePrinter(
        errorCode: ErrorCodes.printerNotFound,
        message: 'Printer unavailable — "$key" is not installed on this '
            'computer, or it has been switched off in Printers.',
        requestedKey: key,
      );

  static UnavailablePrinter _notUsable(PrinterDevice printer) {
    if (!printer.isEnabled) {
      return UnavailablePrinter(
        errorCode: ErrorCodes.printerNotFound,
        message: 'Printer unavailable — "${printer.displayName}" is switched '
            'off in the agent\'s Printers screen.',
        requestedKey: printer.printerKey,
      );
    }
    return UnavailablePrinter(
      errorCode: printer.state == PrinterState.offline
          ? ErrorCodes.printerOffline
          : ErrorCodes.printerError,
      message: 'Printer unavailable — ${printer.state.problemMessage}',
      requestedKey: printer.printerKey,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
