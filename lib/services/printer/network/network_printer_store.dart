import 'dart:async';

import '../../../core/logging/app_logger.dart';
import '../../../core/logging/log_level.dart';
import '../../../core/storage/dao/settings_dao.dart';
import '../../../features/printers/domain/network_printer.dart';

/// Persists the operator's list of directly-addressed network printers.
///
/// Stored in the generic settings table rather than the printers table: the
/// printers table is a cache of what *discovery* found and is rebuilt on every
/// pass, whereas this list is configuration and must survive a discovery that
/// returns nothing (an unplugged switch, a printer powered off overnight).
class NetworkPrinterStore {
  NetworkPrinterStore({required SettingsDao settings, AppLogger? logger})
      : _settings = settings,
        _logger = logger;

  static const String storageKey = 'network_printers';

  final SettingsDao _settings;
  final AppLogger? _logger;

  List<NetworkPrinter>? _cache;

  final StreamController<List<NetworkPrinter>> _changes =
      StreamController<List<NetworkPrinter>>.broadcast();

  Stream<List<NetworkPrinter>> get changes => _changes.stream;

  /// The configured printers, cached after the first read.
  Future<List<NetworkPrinter>> all() async {
    final cached = _cache;
    if (cached != null) return cached;

    final values = await _settings.readAll();
    final raw = values[storageKey];

    final printers = <NetworkPrinter>[];

    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final printer = NetworkPrinter.fromJson(entry.cast<String, dynamic>());
        // One malformed entry must not cost the operator the whole list.
        if (printer != null) printers.add(printer);
      }
    }

    _cache = printers;
    return printers;
  }

  Future<NetworkPrinter?> byKey(String printerKey) async {
    for (final printer in await all()) {
      if (printer.printerKey == printerKey) return printer;
    }
    return null;
  }

  /// Adds a printer, or replaces one already at the same address.
  Future<List<NetworkPrinter>> save(NetworkPrinter printer) async {
    if (!printer.isValid) return all();

    final printers = List<NetworkPrinter>.from(await all())
      ..removeWhere((NetworkPrinter p) => p.printerKey == printer.printerKey)
      ..add(printer);

    await _persist(printers);

    _logger?.info(
      LogCategory.printer,
      'Network printer saved',
      context: <String, Object?>{'printer': printer.printerKey},
    );

    return printers;
  }

  Future<List<NetworkPrinter>> remove(String printerKey) async {
    final printers = List<NetworkPrinter>.from(await all())
      ..removeWhere((NetworkPrinter p) => p.printerKey == printerKey);

    await _persist(printers);

    _logger?.info(
      LogCategory.printer,
      'Network printer removed',
      context: <String, Object?>{'printer': printerKey},
    );

    return printers;
  }

  Future<void> _persist(List<NetworkPrinter> printers) async {
    _cache = printers;

    await _settings.writeAll(<String, dynamic>{
      storageKey: printers.map((NetworkPrinter p) => p.toJson()).toList(),
    });

    if (!_changes.isClosed) _changes.add(printers);
  }

  Future<void> dispose() async => _changes.close();
}
