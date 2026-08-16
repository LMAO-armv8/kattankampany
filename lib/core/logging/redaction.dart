/// Removes secrets from anything that is about to be written to a log sink.
///
/// This runs on *every* record before any sink sees it. It is deliberately
/// aggressive: a false positive costs a little readability, a false negative
/// leaks a bearer token into a support bundle.
abstract final class Redaction {
  static const String mask = '***REDACTED***';

  /// Context keys whose values are always replaced wholesale.
  static const Set<String> sensitiveKeys = <String>{
    'authorization',
    'token',
    'access_token',
    'accesstoken',
    'refresh_token',
    'refreshtoken',
    'bearer',
    'password',
    'passwd',
    'secret',
    'client_secret',
    'api_key',
    'apikey',
    'x-api-key',
    'pairing_code',
    'pairingcode',
    'credentials',
    'cookie',
    'set-cookie',
    'signature',
    'nonce',
    'entropy',
    'private_key',
  };

  // Authorization: Bearer <token>
  static final RegExp _bearer =
      RegExp(r'bearer\s+[A-Za-z0-9\-._~+/=]{8,}', caseSensitive: false);

  // "token": "...."  /  token=....  /  api_key: ....
  static final RegExp _labelled = RegExp(
    r'''((?:access_|refresh_)?token|api[_-]?key|secret|password|pairing_code)["']?\s*[:=]\s*["']?[^"'\s,}&]{6,}''',
    caseSensitive: false,
  );

  // Application-password style prefixed tokens issued by the plugin.
  static final RegExp _prefixedToken = RegExp(r'\bwpm_(?:at|rt)_[A-Za-z0-9]{8,}\b');

  // Pairing codes: XXX-XXX-XXX
  static final RegExp _pairingCode =
      RegExp(r'\b[A-Z0-9]{3}-[A-Z0-9]{3}-[A-Z0-9]{3}\b');

  /// Redacts free text.
  static String text(String input) {
    if (input.isEmpty) return input;
    var output = input.replaceAll(_bearer, 'Bearer $mask');
    output = output.replaceAllMapped(
      _labelled,
      (match) => '${match.group(1)}=$mask',
    );
    output = output.replaceAll(_prefixedToken, mask);
    output = output.replaceAll(_pairingCode, mask);
    return output;
  }

  /// Redacts a structured context map (recursively).
  static Map<String, Object?> map(Map<String, Object?> input) {
    if (input.isEmpty) return input;
    final result = <String, Object?>{};
    input.forEach((key, value) {
      if (sensitiveKeys.contains(key.toLowerCase())) {
        result[key] = mask;
        return;
      }
      result[key] = _value(value);
    });
    return result;
  }

  static Object? _value(Object? value) {
    if (value is String) return text(value);
    if (value is Map) return map(value.cast<String, Object?>());
    if (value is Iterable) return value.map(_value).toList(growable: false);
    return value;
  }

  /// Strips credentials and query strings from a URL before logging it.
  static String url(String input) {
    try {
      final uri = Uri.parse(input);
      final sanitised = uri.replace(
        userInfo: '',
        queryParameters: uri.queryParameters.isEmpty
            ? null
            : <String, String>{
                for (final entry in uri.queryParameters.entries)
                  entry.key: sensitiveKeys.contains(entry.key.toLowerCase())
                      ? mask
                      : entry.value,
              },
      );
      return sanitised.toString();
    } catch (_) {
      return text(input);
    }
  }
}
