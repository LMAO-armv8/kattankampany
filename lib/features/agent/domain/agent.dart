import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'agent.freezed.dart';
part 'agent.g.dart';

enum AgentStatus {
  /// No pairing has completed yet.
  @JsonValue('unregistered')
  unregistered,

  @JsonValue('active')
  active,

  /// Temporarily switched off by an administrator.
  @JsonValue('disabled')
  disabled,

  /// Credentials withdrawn; the agent must pair again.
  @JsonValue('revoked')
  revoked;

  bool get canSync => this == AgentStatus.active;

  String get label => switch (this) {
        AgentStatus.unregistered => 'Not connected',
        AgentStatus.active => 'Active',
        AgentStatus.disabled => 'Disabled',
        AgentStatus.revoked => 'Revoked',
      };

  static AgentStatus fromWire(String? value) {
    for (final status in AgentStatus.values) {
      if (status.name == value) return status;
    }
    return AgentStatus.unregistered;
  }
}

/// This computer's identity as a print agent for one store.
@freezed
class Agent with _$Agent {
  const factory Agent({
    required String id,
    required String storeId,
    String? serverAgentId,
    required String name,
    required String machineName,
    required String osDescription,
    required String appVersion,
    @Default(AgentStatus.unregistered) AgentStatus status,
    DateTime? lastSyncAt,
    DateTime? lastHeartbeatAt,
    @Default(<String, dynamic>{}) Map<String, dynamic> metadata,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _Agent;

  const Agent._();

  factory Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

  bool get isRegistered =>
      serverAgentId != null && status != AgentStatus.unregistered;

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'id': id,
        'store_id': storeId,
        'server_agent_id': serverAgentId,
        'name': name,
        'machine_name': machineName,
        'os_description': osDescription,
        'app_version': appVersion,
        'status': status.name,
        'last_sync_at': lastSyncAt?.millisecondsSinceEpoch,
        'last_heartbeat_at': lastHeartbeatAt?.millisecondsSinceEpoch,
        'metadata_json': jsonEncode(metadata),
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static Agent fromDatabaseRow(Map<String, Object?> row) {
    Map<String, dynamic> metadata = <String, dynamic>{};
    final raw = row['metadata_json'] as String?;
    if (raw != null && raw.isNotEmpty && raw != '{}') {
      try {
        metadata = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        metadata = <String, dynamic>{};
      }
    }
    DateTime? at(String column) {
      final value = row[column] as int?;
      return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
    }

    return Agent(
      id: row['id']! as String,
      storeId: row['store_id']! as String,
      serverAgentId: row['server_agent_id'] as String?,
      name: row['name']! as String,
      machineName: row['machine_name']! as String,
      osDescription: row['os_description']! as String,
      appVersion: row['app_version']! as String,
      status: AgentStatus.fromWire(row['status'] as String?),
      lastSyncAt: at('last_sync_at'),
      lastHeartbeatAt: at('last_heartbeat_at'),
      metadata: metadata,
      createdAt: at('created_at') ?? DateTime.now(),
      updatedAt: at('updated_at') ?? DateTime.now(),
    );
  }
}

/// Connection state shown on the dashboard.
enum AgentConnectionState {
  disconnected,
  connecting,
  connected,
  offline,
  unauthorised,
  paused;

  String get label => switch (this) {
        AgentConnectionState.disconnected => 'Not connected',
        AgentConnectionState.connecting => 'Connecting…',
        AgentConnectionState.connected => 'Connected',
        AgentConnectionState.offline => 'Offline',
        AgentConnectionState.unauthorised => 'Authorisation required',
        AgentConnectionState.paused => 'Paused',
      };
}
