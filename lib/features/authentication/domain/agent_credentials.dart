import 'dart:convert';

/// The bearer credentials issued by the plugin when an administrator approves a
/// pairing request.
///
/// This object is the only place a token exists in memory, and it is never
/// written to the database, never logged, and never included in a diagnostics
/// export. `toString` is overridden so an accidental interpolation cannot leak
/// it.
class AgentCredentials {
  const AgentCredentials({
    required this.token,
    this.tokenType = 'Bearer',
    this.refreshToken,
    this.expiresAt,
    this.scopes = const <String>[],
    this.issuedAt,
  });

  final String token;
  final String tokenType;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;
  final DateTime? issuedAt;

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// True when the token will expire within [window] and should be refreshed
  /// pre-emptively rather than waiting for a 401.
  bool expiresWithin(Duration window) =>
      expiresAt != null && DateTime.now().add(window).isAfter(expiresAt!);

  String get authorizationHeader => '$tokenType $token';

  AgentCredentials copyWith({
    String? token,
    String? tokenType,
    String? refreshToken,
    DateTime? expiresAt,
    List<String>? scopes,
    DateTime? issuedAt,
  }) =>
      AgentCredentials(
        token: token ?? this.token,
        tokenType: tokenType ?? this.tokenType,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
        scopes: scopes ?? this.scopes,
        issuedAt: issuedAt ?? this.issuedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'token': token,
        'token_type': tokenType,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
        if (scopes.isNotEmpty) 'scopes': scopes,
        if (issuedAt != null) 'issued_at': issuedAt!.toIso8601String(),
      };

  static AgentCredentials fromJson(Map<String, dynamic> json) =>
      AgentCredentials(
        token: (json['token'] as String?) ?? '',
        tokenType: (json['token_type'] as String?) ?? 'Bearer',
        refreshToken: json['refresh_token'] as String?,
        expiresAt: json['expires_at'] == null
            ? null
            : DateTime.tryParse(json['expires_at'] as String),
        scopes: (json['scopes'] as List<dynamic>? ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(growable: false),
        issuedAt: json['issued_at'] == null
            ? null
            : DateTime.tryParse(json['issued_at'] as String),
      );

  String encode() => jsonEncode(toJson());

  static AgentCredentials decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Deliberately opaque. Never print a credential.
  @override
  String toString() => 'AgentCredentials(token: <redacted>, '
      'type: $tokenType, expires: ${expiresAt?.toIso8601String() ?? 'never'})';
}
