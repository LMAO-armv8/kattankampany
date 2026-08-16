import 'package:freezed_annotation/freezed_annotation.dart';

part 'store_connection.freezed.dart';
part 'store_connection.g.dart';

/// A paired WooCommerce installation.
///
/// The schema and the API client are already per-store so that supporting
/// several stores later is a UI change, not a rewrite.
@freezed
class StoreConnection with _$StoreConnection {
  const factory StoreConnection({
    required String id,
    required String baseUrl,
    String? storeName,
    @Default('wpm/v1') String apiNamespace,
    @Default(true) bool isActive,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _StoreConnection;

  const StoreConnection._();

  factory StoreConnection.fromJson(Map<String, dynamic> json) =>
      _$StoreConnectionFromJson(json);

  /// `https://store.example/wp-json/wpm/v1`
  String get apiBaseUrl {
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$root/wp-json/$apiNamespace';
  }

  Uri get origin {
    final uri = Uri.parse(baseUrl);
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
  }

  String get displayHost {
    try {
      return Uri.parse(baseUrl).host;
    } catch (_) {
      return baseUrl;
    }
  }

  String get displayName =>
      (storeName != null && storeName!.isNotEmpty) ? storeName! : displayHost;

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'id': id,
        'base_url': baseUrl,
        'store_name': storeName,
        'api_namespace': apiNamespace,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static StoreConnection fromDatabaseRow(Map<String, Object?> row) =>
      StoreConnection(
        id: row['id']! as String,
        baseUrl: row['base_url']! as String,
        storeName: row['store_name'] as String?,
        apiNamespace: (row['api_namespace'] as String?) ?? 'wpm/v1',
        isActive: (row['is_active'] as int? ?? 1) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int?) ?? 0,),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['updated_at'] as int?) ?? 0,),
      );
}
