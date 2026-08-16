import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../core/config/app_info.dart';
import '../../core/config/settings_repository.dart';
import '../../core/errors/app_exception.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/network/api_client.dart';
import '../../core/network/connectivity_monitor.dart';
import '../../core/security/secure_credential_store.dart';
import '../../core/security/url_validator.dart';
import '../../core/storage/dao/agent_dao.dart';
import '../../core/storage/dao/store_dao.dart';
import '../../features/agent/domain/agent.dart';
import '../../features/agent/domain/store_connection.dart';
import '../../features/authentication/domain/agent_credentials.dart';
import 'dto/pairing_dto.dart';
import 'print_agent_api.dart';

/// Progress of a pairing attempt, streamed to the "Connect your store" screen.
class PairingProgress {
  const PairingProgress({
    required this.state,
    this.session,
    this.message,
    this.error,
  });

  final PairingState state;
  final PairingSession? session;
  final String? message;
  final AppException? error;

  bool get isWaiting => state == PairingState.pending;
  bool get isApproved => state == PairingState.approved;
  bool get hasFailed => error != null;
}

/// Owns the agent's identity: which store it is paired with, its credentials,
/// and the authenticated API client built from them.
///
/// Everything else in the application asks this object for `api` rather than
/// constructing a client, so there is exactly one place where a token is read
/// and exactly one place where "not paired" is decided.
class AgentSession {
  AgentSession({
    required StoreDao storeDao,
    required AgentDao agentDao,
    required SecureCredentialStore credentialStore,
    required SettingsRepository settings,
    AppLogger? logger,
    ConnectivityMonitor? connectivity,
    Uuid uuid = const Uuid(),
  })  : _storeDao = storeDao,
        _agentDao = agentDao,
        _credentialStore = credentialStore,
        _settings = settings,
        _logger = logger,
        _connectivity = connectivity,
        _uuid = uuid;

  final StoreDao _storeDao;
  final AgentDao _agentDao;
  final SecureCredentialStore _credentialStore;
  final SettingsRepository _settings;
  final AppLogger? _logger;
  final ConnectivityMonitor? _connectivity;
  final Uuid _uuid;

  final StreamController<AgentConnectionState> _stateController =
      StreamController<AgentConnectionState>.broadcast();

  StoreConnection? _store;
  Agent? _agent;
  AgentCredentials? _credentials;
  ApiClient? _client;
  PrintAgentApi? _api;
  AgentConnectionState _state = AgentConnectionState.disconnected;
  DateTime? _lastSuccessfulSyncAt;

  StoreConnection? get store => _store;
  Agent? get agent => _agent;
  bool get isPaired => _store != null && _agent != null && _credentials != null;
  AgentConnectionState get state => _state;
  DateTime? get lastSuccessfulSyncAt => _lastSuccessfulSyncAt;
  Stream<AgentConnectionState> get stateChanges => _stateController.stream;

  /// Throws [AuthException] when the agent is not paired, so callers do not
  /// have to null-check on every use.
  PrintAgentApi get api {
    final value = _api;
    if (value == null) {
      throw const AuthException(
        userMessage: 'This computer is not connected to a store yet.',
        technicalDetail: 'AgentSession.api accessed before pairing.',
      );
    }
    return value;
  }

  PrintAgentApi? get apiOrNull => _api;

  String? get serverAgentId => _agent?.serverAgentId;

  // -------------------------------------------------------------------------
  // Startup
  // -------------------------------------------------------------------------

  /// Restores a previous pairing from disk. Called once during bootstrap.
  Future<bool> restore() async {
    try {
      _store = await _storeDao.findActive();
      if (_store == null) {
        _setState(AgentConnectionState.disconnected);
        return false;
      }

      _agent = await _agentDao.findByStore(_store!.id);
      if (_agent == null) {
        _setState(AgentConnectionState.disconnected);
        return false;
      }

      _credentials = await _credentialStore.read(_agent!.id);
      if (_credentials == null) {
        // The store and agent rows survived but the encrypted token did not —
        // typically a different Windows user, or a restored profile.
        _logger?.warn(
          LogCategory.auth,
          'Agent record found but no usable credentials; re-pairing required',
        );
        _setState(AgentConnectionState.unauthorised);
        return false;
      }

      _buildClient();
      _connectivity?.setStore(_store!.baseUrl);
      _setState(AgentConnectionState.connecting);
      _logger?.info(
        LogCategory.auth,
        'Restored pairing',
        context: <String, Object?>{
          'store': _store!.displayHost,
          'agent': _agent!.name,
        },
      );
      return true;
    } catch (e, st) {
      _logger?.exception(LogCategory.auth, 'Could not restore pairing', e, st);
      _setState(AgentConnectionState.disconnected);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Pairing
  // -------------------------------------------------------------------------

  /// Runs the full pairing handshake and yields progress.
  ///
  /// No WordPress username or password is requested at any point: the agent
  /// asks for a code, the operator has an administrator approve it in wp-admin,
  /// and the plugin returns credentials scoped to this device.
  Stream<PairingProgress> pair({
    required String rawStoreUrl,
    required String agentName,
    Duration timeout = const Duration(minutes: 10),
  }) async* {
    final normalised = UrlValidator.normaliseStoreUrl(rawStoreUrl);
    if (normalised == null) {
      yield PairingProgress(
        state: PairingState.unknown,
        error: const ConfigurationException(
          userMessage:
              'That store address does not look right. Enter your store URL, '
              'for example https://your-store.com',
        ),
      );
      return;
    }

    final trimmedName = agentName.trim();
    if (trimmedName.isEmpty) {
      yield PairingProgress(
        state: PairingState.unknown,
        error: const ConfigurationException(
          userMessage: 'Give this computer a name so you can identify it in '
              'your store, for example "Warehouse PC".',
        ),
      );
      return;
    }

    // A temporary, unauthenticated client just for the handshake.
    final pairingClient = ApiClient(
      baseUrl: '$normalised/wp-json/${_settingsNamespace()}',
      logger: _logger,
      connectTimeout: _settings.current.connectionTimeout,
    );
    final pairingApi = PrintAgentApi(
      client: pairingClient,
      storeBaseUrl: normalised,
      logger: _logger,
    );

    PairingSession session;
    try {
      yield const PairingProgress(
        state: PairingState.pending,
        message: 'Contacting your store…',
      );
      session = await pairingApi.startPairing(agentName: trimmedName);
    } on AppException catch (e) {
      pairingClient.close();
      yield PairingProgress(state: PairingState.unknown, error: e);
      return;
    } catch (e, st) {
      pairingClient.close();
      yield PairingProgress(
        state: PairingState.unknown,
        error: asAppException(e, st),
      );
      return;
    }

    yield PairingProgress(
      state: PairingState.pending,
      session: session,
      message: 'Waiting for approval in your store…',
    );

    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(session.pollInterval);

        PairingStatus status;
        try {
          status = await pairingApi.pairingStatus(session.pairingId);
        } on NetworkException {
          // Transient: keep waiting rather than abandoning the operator's code.
          yield PairingProgress(
            state: PairingState.pending,
            session: session,
            message: 'Connection interrupted — still waiting…',
          );
          continue;
        } on RateLimitException {
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }

        switch (status.state) {
          case PairingState.pending:
            continue;

          case PairingState.approved:
            if (!status.isApproved) {
              yield PairingProgress(
                state: PairingState.unknown,
                session: session,
                error: const PairingException(
                  userMessage: 'Your store approved this computer but did not '
                      'send credentials. Please try again.',
                ),
              );
              return;
            }
            await _persistPairing(
              storeBaseUrl: normalised,
              storeName: status.storeName,
              agentName: status.agentName ?? trimmedName,
              serverAgentId: status.serverAgentId,
              credentials: status.credentials!,
            );
            yield PairingProgress(
              state: PairingState.approved,
              session: session,
              message: 'Connected to ${_store?.displayName ?? normalised}',
            );
            return;

          case PairingState.denied:
          case PairingState.expired:
          case PairingState.unknown:
            yield PairingProgress(
              state: status.state,
              session: session,
              error: PairingException(userMessage: status.state.message),
            );
            return;
        }
      }

      yield PairingProgress(
        state: PairingState.expired,
        session: session,
        error: const PairingException(
          userMessage: 'The pairing request timed out. Start again to get a '
              'new code.',
        ),
      );
    } finally {
      pairingClient.close();
    }
  }

  String _settingsNamespace() => 'wpm/v1';

  Future<void> _persistPairing({
    required String storeBaseUrl,
    required String? storeName,
    required String agentName,
    required String? serverAgentId,
    required AgentCredentials credentials,
  }) async {
    final now = DateTime.now();
    final info = AppInfo.instance;

    final existingStore = await _storeDao.findByBaseUrl(storeBaseUrl);
    final store = (existingStore ??
            StoreConnection(
              id: _uuid.v4(),
              baseUrl: storeBaseUrl,
              createdAt: now,
              updatedAt: now,
            ))
        .copyWith(storeName: storeName, isActive: true, updatedAt: now);
    await _storeDao.upsert(store);
    await _storeDao.setActive(store.id);

    final existingAgent = await _agentDao.findByStore(store.id);
    final agent = (existingAgent ??
            Agent(
              id: _uuid.v4(),
              storeId: store.id,
              name: agentName,
              machineName: info.machineName,
              osDescription: info.osDescription,
              appVersion: info.fullVersion,
              createdAt: now,
              updatedAt: now,
            ))
        .copyWith(
      name: agentName,
      serverAgentId: serverAgentId,
      machineName: info.machineName,
      osDescription: info.osDescription,
      appVersion: info.fullVersion,
      status: AgentStatus.active,
      updatedAt: now,
    );
    await _agentDao.upsert(agent);

    await _credentialStore.write(
      agent.id,
      credentials.copyWith(issuedAt: credentials.issuedAt ?? now),
    );

    _store = store;
    _agent = agent;
    _credentials = credentials;
    _buildClient();
    _connectivity?.setStore(store.baseUrl);
    _setState(AgentConnectionState.connected);

    _logger?.info(
      LogCategory.auth,
      'Agent paired',
      context: <String, Object?>{
        'store': store.displayHost,
        'agent': agent.name,
        'server_agent_id': serverAgentId,
      },
    );
  }

  // -------------------------------------------------------------------------
  // Registration refresh
  // -------------------------------------------------------------------------

  /// Confirms the pairing is still valid and refreshes the agent record.
  /// Called on startup after [restore] and after every reconnect.
  Future<bool> verify() async {
    if (!isPaired) return false;
    try {
      final serverAgent = await api.getAgent();
      final updated = _agent!.copyWith(
        serverAgentId: serverAgent.id.isEmpty
            ? _agent!.serverAgentId
            : serverAgent.id,
        name: serverAgent.name.isEmpty ? _agent!.name : serverAgent.name,
        status: serverAgent.status,
        appVersion: AppInfo.instance.fullVersion,
        updatedAt: DateTime.now(),
      );
      await _agentDao.upsert(updated);
      _agent = updated;
      _api?.agentId = updated.serverAgentId;

      if (serverAgent.storeName != null &&
          serverAgent.storeName != _store!.storeName) {
        final store = _store!.copyWith(
          storeName: serverAgent.storeName,
          updatedAt: DateTime.now(),
        );
        await _storeDao.upsert(store);
        _store = store;
      }

      _setState(
        updated.status.canSync
            ? AgentConnectionState.connected
            : AgentConnectionState.unauthorised,
      );
      return updated.status.canSync;
    } on AuthException {
      await _handleUnauthorised();
      return false;
    } on ForbiddenException {
      await _markStatus(AgentStatus.disabled);
      _setState(AgentConnectionState.unauthorised);
      return false;
    } on NetworkException {
      _setState(AgentConnectionState.offline);
      return false;
    } on RequestTimeoutException {
      _setState(AgentConnectionState.offline);
      return false;
    } catch (e, st) {
      _logger?.exception(LogCategory.auth, 'Agent verification failed', e, st);
      return false;
    }
  }

  /// Re-registers the device — used after an app upgrade or an OS change so the
  /// store's device list stays accurate.
  Future<void> reregister() async {
    if (!isPaired) return;
    try {
      final serverAgent = await api.registerAgent(name: _agent!.name);
      final updated = _agent!.copyWith(
        serverAgentId: serverAgent.id,
        status: serverAgent.status,
        appVersion: AppInfo.instance.fullVersion,
        updatedAt: DateTime.now(),
      );
      await _agentDao.upsert(updated);
      _agent = updated;
      _api?.agentId = updated.serverAgentId;
    } on AppException catch (e, st) {
      _logger?.exception(LogCategory.auth, 'Re-registration failed', e, st);
    }
  }

  Future<void> renameAgent(String name) async {
    if (_agent == null) return;
    final updated = _agent!.copyWith(name: name.trim(), updatedAt: DateTime.now());
    await _agentDao.upsert(updated);
    _agent = updated;
    await reregister();
  }

  // -------------------------------------------------------------------------
  // State transitions
  // -------------------------------------------------------------------------

  void markSyncSuccess() {
    _lastSuccessfulSyncAt = DateTime.now();
    _connectivity?.reportSuccess();
    if (_state == AgentConnectionState.offline ||
        _state == AgentConnectionState.connecting) {
      _setState(AgentConnectionState.connected);
    }
    final agent = _agent;
    if (agent != null) {
      unawaited(_agentDao.touchSync(agent.id, _lastSuccessfulSyncAt!));
    }
  }

  void markOffline() {
    _connectivity?.reportFailure();
    if (_state != AgentConnectionState.unauthorised &&
        _state != AgentConnectionState.paused) {
      _setState(AgentConnectionState.offline);
    }
  }

  void markPaused({required bool paused}) {
    if (paused) {
      _setState(AgentConnectionState.paused);
    } else if (isPaired) {
      _setState(AgentConnectionState.connecting);
    }
  }

  Future<void> _handleUnauthorised() async {
    _logger?.warn(
      LogCategory.auth,
      'Store rejected the agent credentials; re-pairing is required',
    );
    await _markStatus(AgentStatus.revoked);
    _setState(AgentConnectionState.unauthorised);
  }

  Future<void> _markStatus(AgentStatus status) async {
    final agent = _agent;
    if (agent == null) return;
    final updated = agent.copyWith(status: status, updatedAt: DateTime.now());
    await _agentDao.upsert(updated);
    _agent = updated;
  }

  // -------------------------------------------------------------------------
  // Unpairing
  // -------------------------------------------------------------------------

  /// Disconnects this computer from its store and destroys the stored token.
  /// Job history is preserved unless [deleteLocalData] is set.
  Future<void> unpair({bool deleteLocalData = false}) async {
    final agent = _agent;
    final store = _store;

    _client?.close();
    _client = null;
    _api = null;
    _credentials = null;

    if (agent != null) {
      await _credentialStore.delete(agent.id);
      if (deleteLocalData) {
        await _agentDao.delete(agent.id);
      } else {
        await _agentDao.updateStatus(agent.id, AgentStatus.unregistered);
      }
    }
    if (store != null && deleteLocalData) {
      await _storeDao.delete(store.id);
    }

    _agent = deleteLocalData ? null : _agent;
    _store = deleteLocalData ? null : _store;
    _setState(AgentConnectionState.disconnected);
    _logger?.info(LogCategory.auth, 'Agent unpaired');
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _buildClient() {
    _client?.close();
    final store = _store!;
    _client = ApiClient(
      baseUrl: store.apiBaseUrl,
      logger: _logger,
      connectTimeout: _settings.current.connectionTimeout,
      agentId: _agent?.serverAgentId,
      tokenProvider: () async {
        final credentials = _credentials;
        if (credentials == null) return null;
        // Refresh pre-emptively when the server issues expiring tokens.
        if (credentials.refreshToken != null &&
            credentials.expiresWithin(const Duration(minutes: 2))) {
          await _refreshToken();
        }
        return _credentials?.token;
      },
      onUnauthorized: (AppException error) {
        unawaited(_handleUnauthorised());
      },
    );
    _api = PrintAgentApi(
      client: _client!,
      storeBaseUrl: store.baseUrl,
      logger: _logger,
    );
  }

  Future<void> _refreshToken() async {
    final credentials = _credentials;
    final agent = _agent;
    if (credentials?.refreshToken == null || agent == null) return;
    try {
      final refreshed = await api.refreshCredentials(credentials!.refreshToken!);
      _credentials = refreshed;
      await _credentialStore.write(agent.id, refreshed);
      _logger?.info(LogCategory.auth, 'Access token refreshed');
    } on AppException catch (e, st) {
      _logger?.exception(LogCategory.auth, 'Token refresh failed', e, st);
    }
  }

  void _setState(AgentConnectionState next) {
    if (next == _state) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() async {
    _client?.close();
    await _stateController.close();
  }
}
