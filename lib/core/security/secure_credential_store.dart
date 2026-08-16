import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../features/authentication/domain/agent_credentials.dart';
import '../config/app_paths.dart';
import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import '../logging/log_level.dart';
import 'dpapi.dart';

/// Where the agent's bearer token lives.
///
/// Credentials are **never** stored in the SQLite database, in settings, or in
/// any file the agent will later export for support. They live in their own
/// file, encrypted by the operating system.
abstract class SecureCredentialStore {
  Future<AgentCredentials?> read(String agentId);
  Future<void> write(String agentId, AgentCredentials credentials);
  Future<void> delete(String agentId);
  Future<bool> exists(String agentId);

  /// Whether the underlying storage actually provides encryption. Surfaced on
  /// the Diagnostics screen so an operator is never misled about it.
  bool get isEncrypted;

  String get description;
}

/// Windows implementation: DPAPI, user scope, with an application entropy salt.
///
/// The ciphertext is bound to the Windows user account, so copying
/// `%APPDATA%\WooCommercePrintAgent\credentials\` to another machine — or
/// reading it as another user — yields nothing usable.
class DpapiCredentialStore implements SecureCredentialStore {
  DpapiCredentialStore({required AppPaths paths, AppLogger? logger})
      : _paths = paths,
        _logger = logger;

  final AppPaths _paths;
  final AppLogger? _logger;

  /// Application-specific entropy. Not a secret — it scopes the ciphertext to
  /// this application so another program running as the same user cannot simply
  /// call CryptUnprotectData on the file.
  static final Uint8List _entropy = Uint8List.fromList(
    utf8.encode('com.woocommerce.printagent.credentials.v1'),
  );

  @override
  bool get isEncrypted => true;

  @override
  String get description =>
      'Windows Data Protection API (per-user encryption)';

  File _fileFor(String agentId) =>
      File(p.join(_paths.credentialsDir.path, '${_sanitise(agentId)}.bin'));

  @override
  Future<bool> exists(String agentId) async => _fileFor(agentId).existsSync();

  @override
  Future<AgentCredentials?> read(String agentId) async {
    final file = _fileFor(agentId);
    if (!file.existsSync()) return null;
    try {
      final ciphertext = await file.readAsBytes();
      final plaintext = Dpapi.unprotect(ciphertext, entropy: _entropy);
      return AgentCredentials.decode(utf8.decode(plaintext));
    } on DpapiException catch (e) {
      // Wrong user, wrong machine, or a corrupted file. The agent must re-pair;
      // it must not fall back to anything less safe.
      _logger?.warn(
        LogCategory.security,
        'Stored credentials could not be decrypted; re-pairing is required',
        context: <String, Object?>{'agent_id': agentId},
        error: e.message,
      );
      return null;
    } catch (e, st) {
      _logger?.exception(
        LogCategory.security,
        'Credential read failed',
        e,
        st,
        <String, Object?>{'agent_id': agentId},
      );
      return null;
    }
  }

  @override
  Future<void> write(String agentId, AgentCredentials credentials) async {
    try {
      final plaintext = Uint8List.fromList(utf8.encode(credentials.encode()));
      final ciphertext = Dpapi.protect(plaintext, entropy: _entropy);
      final file = _fileFor(agentId);
      await file.parent.create(recursive: true);
      // Write to a temporary file and rename, so an interrupted write cannot
      // leave a truncated credential file behind.
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(ciphertext, flush: true);
      if (file.existsSync()) await file.delete();
      await temp.rename(file.path);
      _logger?.info(
        LogCategory.security,
        'Credentials stored (encrypted)',
        context: <String, Object?>{'agent_id': agentId},
      );
    } on DpapiException catch (e, st) {
      throw SecurityStoreException(
        technicalDetail: e.message,
        cause: e,
        stackTrace: st,
      );
    } catch (e, st) {
      throw SecurityStoreException(
        technicalDetail: e.toString(),
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> delete(String agentId) async {
    final file = _fileFor(agentId);
    try {
      if (file.existsSync()) await file.delete();
      _logger?.info(
        LogCategory.security,
        'Credentials deleted',
        context: <String, Object?>{'agent_id': agentId},
      );
    } catch (e, st) {
      _logger?.exception(LogCategory.security, 'Credential delete failed', e, st);
    }
  }

  static String _sanitise(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// Development/CI fallback for hosts without DPAPI.
///
/// It is deliberately loud: [isEncrypted] is false, the Diagnostics screen shows
/// a warning, and a warning is written to the log every time it is used. It
/// exists so the app can run on a developer's macOS or Linux machine — it is not
/// an acceptable configuration for a production Windows install, and on Windows
/// it is never selected.
class UnencryptedFileCredentialStore implements SecureCredentialStore {
  UnencryptedFileCredentialStore({required AppPaths paths, AppLogger? logger})
      : _paths = paths,
        _logger = logger;

  final AppPaths _paths;
  final AppLogger? _logger;

  @override
  bool get isEncrypted => false;

  @override
  String get description =>
      'Unencrypted local file (development fallback — not for production use)';

  File _fileFor(String agentId) => File(
        p.join(
          _paths.credentialsDir.path,
          '${agentId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json',
        ),
      );

  @override
  Future<bool> exists(String agentId) async => _fileFor(agentId).existsSync();

  @override
  Future<AgentCredentials?> read(String agentId) async {
    final file = _fileFor(agentId);
    if (!file.existsSync()) return null;
    _warn();
    try {
      return AgentCredentials.decode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String agentId, AgentCredentials credentials) async {
    _warn();
    final file = _fileFor(agentId);
    await file.parent.create(recursive: true);
    await file.writeAsString(credentials.encode(), flush: true);
  }

  @override
  Future<void> delete(String agentId) async {
    final file = _fileFor(agentId);
    if (file.existsSync()) await file.delete();
  }

  void _warn() => _logger?.warn(
        LogCategory.security,
        'Credentials are being stored WITHOUT encryption — '
        'Windows credential protection is unavailable on this host',
      );
}

/// Chooses the right store for the current platform.
SecureCredentialStore createCredentialStore({
  required AppPaths paths,
  AppLogger? logger,
}) {
  if (Platform.isWindows && Dpapi.isSupported) {
    return DpapiCredentialStore(paths: paths, logger: logger);
  }
  return UnencryptedFileCredentialStore(paths: paths, logger: logger);
}
