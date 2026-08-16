import 'dart:async';

import '../logging/app_logger.dart';
import '../logging/log_level.dart';
import '../storage/dao/settings_dao.dart';
import 'app_settings.dart';

/// Single source of truth for [AppSettings].
///
/// Services read `current` synchronously (it is always populated after
/// [load]) and subscribe to [changes] when they need to react — the sync loop
/// re-times itself, the logger adjusts its level, the autostart service rewrites
/// the registry entry.
class SettingsRepository {
  SettingsRepository({required SettingsDao dao, AppLogger? logger})
      : _dao = dao,
        _logger = logger;

  final SettingsDao _dao;
  final AppLogger? _logger;

  final StreamController<AppSettings> _controller =
      StreamController<AppSettings>.broadcast();

  AppSettings _current = AppSettings.defaults;

  AppSettings get current => _current;

  Stream<AppSettings> get changes => _controller.stream;

  Future<AppSettings> load() async {
    try {
      final stored = await _dao.readAll();
      if (stored.isEmpty) {
        _current = AppSettings.defaults;
      } else {
        // Unknown keys from a newer build are ignored; missing keys fall back to
        // the field defaults, so upgrading never resets an operator's setup.
        _current = AppSettings.fromJson(<String, dynamic>{
          ...AppSettings.defaults.toJson(),
          ...stored,
        }).sanitised();
      }
    } catch (e, st) {
      _logger?.exception(
        LogCategory.storage,
        'Settings could not be read; using defaults',
        e,
        st,
      );
      _current = AppSettings.defaults;
    }
    _controller.add(_current);
    return _current;
  }

  /// Persists [next] and notifies listeners. Values are clamped first.
  Future<AppSettings> save(AppSettings next) async {
    final sanitised = next.sanitised();
    if (sanitised == _current) return _current;
    _current = sanitised;
    try {
      await _dao.writeAll(sanitised.toJson());
    } catch (e, st) {
      _logger?.exception(LogCategory.storage, 'Settings could not be saved', e, st);
    }
    _controller.add(_current);
    return _current;
  }

  /// Convenience for a single-field change from the settings UI.
  Future<AppSettings> update(
    AppSettings Function(AppSettings current) transform,
  ) =>
      save(transform(_current));

  Future<AppSettings> resetToDefaults() async {
    await _dao.clear();
    _current = AppSettings.defaults;
    _controller.add(_current);
    return _current;
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
