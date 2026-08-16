import '../../../features/agent/domain/agent.dart';

/// The agent record as the plugin sees it (`GET /agents/me`,
/// `POST /agents/register`).
class ServerAgent {
  const ServerAgent({
    required this.id,
    required this.name,
    required this.status,
    this.storeName,
    this.storeUrl,
    this.serverTime,
    this.suggestedSettings = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final AgentStatus status;
  final String? storeName;
  final String? storeUrl;
  final DateTime? serverTime;

  /// Server-suggested values (poll interval, claim batch size). Local settings
  /// always win where the operator has set them explicitly.
  final Map<String, dynamic> suggestedSettings;

  int? get suggestedPollIntervalSeconds =>
      (suggestedSettings['poll_interval_seconds'] as num?)?.toInt();

  int? get suggestedClaimBatch =>
      (suggestedSettings['max_claim_batch'] as num?)?.toInt();

  static ServerAgent fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    return ServerAgent(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] as String?) ?? '',
      status: AgentStatus.fromWire(json['status'] as String? ?? 'active'),
      storeName: json['store_name'] as String?,
      storeUrl: json['store_url'] as String?,
      serverTime: json['server_time'] == null
          ? null
          : DateTime.tryParse(json['server_time'] as String)?.toLocal(),
      suggestedSettings:
          settings is Map ? settings.cast<String, dynamic>() : const {},
    );
  }
}

/// A command pushed to the agent on the heartbeat response. Lets an
/// administrator act on a device without a WebSocket connection.
class ServerCommand {
  const ServerCommand({required this.type, this.payload = const {}});

  final String type;
  final Map<String, dynamic> payload;

  static const String syncNow = 'sync_now';
  static const String pause = 'pause';
  static const String resume = 'resume';
  static const String refreshPrinters = 'refresh_printers';
  static const String testPrint = 'test_print';

  String? get printerKey => payload['printer_key'] as String?;

  static ServerCommand fromJson(Map<String, dynamic> json) => ServerCommand(
        type: (json['type'] as String?) ?? '',
        payload: json.containsKey('payload') && json['payload'] is Map
            ? (json['payload'] as Map).cast<String, dynamic>()
            : json,
      );
}

/// Response to `POST /agents/heartbeat`.
class HeartbeatResponse {
  const HeartbeatResponse({
    this.serverTime,
    this.commands = const <ServerCommand>[],
  });

  final DateTime? serverTime;
  final List<ServerCommand> commands;

  static HeartbeatResponse fromJson(Map<String, dynamic> json) {
    final raw = json['commands'];
    return HeartbeatResponse(
      serverTime: json['server_time'] == null
          ? null
          : DateTime.tryParse(json['server_time'] as String)?.toLocal(),
      commands: raw is List
          ? raw
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> e) =>
                  ServerCommand.fromJson(e.cast<String, dynamic>()),)
              .where((ServerCommand c) => c.type.isNotEmpty)
              .toList(growable: false)
          : const <ServerCommand>[],
    );
  }
}
