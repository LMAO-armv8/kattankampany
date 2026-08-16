import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_info.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/errors/app_exception.dart';
import '../../../../services/api/agent_session.dart';
import '../../../../services/api/dto/pairing_dto.dart';

/// UI state for "Connect your store".
class PairingUiState {
  const PairingUiState({
    this.isConnecting = false,
    this.session,
    this.message,
    this.error,
    this.completed = false,
  });

  final bool isConnecting;
  final PairingSession? session;
  final String? message;
  final AppException? error;
  final bool completed;

  bool get awaitingApproval => isConnecting && session != null;

  PairingUiState copyWith({
    bool? isConnecting,
    PairingSession? session,
    String? message,
    AppException? error,
    bool? completed,
    bool clearError = false,
    bool clearSession = false,
  }) =>
      PairingUiState(
        isConnecting: isConnecting ?? this.isConnecting,
        session: clearSession ? null : (session ?? this.session),
        message: message ?? this.message,
        error: clearError ? null : (error ?? this.error),
        completed: completed ?? this.completed,
      );
}

class PairingController extends StateNotifier<PairingUiState> {
  PairingController(this._ref) : super(const PairingUiState());

  final Ref _ref;
  StreamSubscription<PairingProgress>? _subscription;

  /// A sensible default so the operator usually only has to press Connect.
  String get suggestedAgentName => AppInfo.instance.machineName;

  Future<void> connect({
    required String storeUrl,
    required String agentName,
  }) async {
    if (state.isConnecting) return;
    await _subscription?.cancel();

    state = const PairingUiState(
      isConnecting: true,
      message: 'Contacting your store…',
    );

    final session = _ref.read(agentSessionProvider);
    final completer = Completer<void>();

    _subscription = session
        .pair(rawStoreUrl: storeUrl, agentName: agentName)
        .listen(
      (PairingProgress progress) {
        if (progress.hasFailed) {
          state = state.copyWith(
            isConnecting: false,
            error: progress.error,
            message: null,
          );
          return;
        }
        if (progress.isApproved) {
          state = state.copyWith(
            isConnecting: false,
            completed: true,
            message: progress.message,
            clearError: true,
          );
          return;
        }
        state = state.copyWith(
          isConnecting: true,
          session: progress.session,
          message: progress.message,
          clearError: true,
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        state = state.copyWith(
          isConnecting: false,
          error: asAppException(error, stackTrace),
        );
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
        if (state.isConnecting) {
          state = state.copyWith(isConnecting: false);
        }
      },
      cancelOnError: false,
    );

    await completer.future;

    if (state.completed) {
      // Bring the background services up for the newly paired store without
      // requiring a restart.
      await _ref.read(lifecycleProvider).onPaired();
    }
  }

  Future<void> cancel() async {
    await _subscription?.cancel();
    _subscription = null;
    state = const PairingUiState();
  }

  void clearError() => state = state.copyWith(clearError: true);

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

final StateNotifierProvider<PairingController, PairingUiState>
    pairingControllerProvider =
    StateNotifierProvider<PairingController, PairingUiState>(
  (Ref ref) => PairingController(ref),
);
