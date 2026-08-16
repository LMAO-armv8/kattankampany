import '../../../features/authentication/domain/agent_credentials.dart';

/// Response to `POST /pairing/start`.
class PairingSession {
  const PairingSession({
    required this.pairingId,
    required this.pairingCode,
    this.verificationUrl,
    this.expiresAt,
    this.pollInterval = const Duration(seconds: 3),
  });

  final String pairingId;

  /// Shown to the operator so an administrator can match the request in
  /// wp-admin. Short-lived and single-use.
  final String pairingCode;

  /// Deep link to the approval screen; opened in the operator's browser.
  final String? verificationUrl;

  final DateTime? expiresAt;
  final Duration pollInterval;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  Duration? get timeRemaining {
    if (expiresAt == null) return null;
    final remaining = expiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  static PairingSession fromJson(Map<String, dynamic> json) => PairingSession(
        pairingId: (json['pairing_id'] ?? json['id'] ?? '').toString(),
        pairingCode: (json['pairing_code'] ?? json['code'] ?? '').toString(),
        verificationUrl: json['verification_url'] as String?,
        expiresAt: json['expires_at'] == null
            ? null
            : DateTime.tryParse(json['expires_at'] as String)?.toLocal(),
        pollInterval: Duration(
          seconds:
              ((json['poll_interval_seconds'] as num?)?.toInt() ?? 3).clamp(1, 30),
        ),
      );
}

enum PairingState {
  pending,
  approved,
  denied,
  expired,
  unknown;

  bool get isTerminal => this != PairingState.pending;

  static PairingState fromWire(String? value) => switch (value?.toLowerCase()) {
        'pending' || 'waiting' => PairingState.pending,
        'approved' || 'paired' || 'complete' => PairingState.approved,
        'denied' || 'rejected' => PairingState.denied,
        'expired' => PairingState.expired,
        _ => PairingState.unknown,
      };

  String get message => switch (this) {
        PairingState.pending => 'Waiting for an administrator to approve…',
        PairingState.approved => 'Approved.',
        PairingState.denied =>
          'The pairing request was declined in your store.',
        PairingState.expired =>
          'The pairing request expired. Start again to get a new code.',
        PairingState.unknown =>
          'Your store returned an unexpected pairing status.',
      };
}

/// Response to `GET /pairing/{id}`.
class PairingStatus {
  const PairingStatus({
    required this.state,
    this.credentials,
    this.serverAgentId,
    this.agentName,
    this.storeName,
    this.storeUrl,
    this.expiresAt,
  });

  final PairingState state;

  /// Present exactly once, when [state] is [PairingState.approved].
  final AgentCredentials? credentials;
  final String? serverAgentId;
  final String? agentName;
  final String? storeName;
  final String? storeUrl;
  final DateTime? expiresAt;

  bool get isApproved =>
      state == PairingState.approved && credentials != null;

  static PairingStatus fromJson(Map<String, dynamic> json) {
    final agent = json['agent'];
    final credentialsRaw = json['credentials'];
    return PairingStatus(
      state: PairingState.fromWire(json['status'] as String?),
      credentials: credentialsRaw is Map
          ? AgentCredentials.fromJson(credentialsRaw.cast<String, dynamic>())
          : null,
      serverAgentId: agent is Map ? agent['id']?.toString() : null,
      agentName: agent is Map ? agent['name'] as String? : null,
      storeName: agent is Map ? agent['store_name'] as String? : null,
      storeUrl: agent is Map ? agent['store_url'] as String? : null,
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.tryParse(json['expires_at'] as String)?.toLocal(),
    );
  }
}
