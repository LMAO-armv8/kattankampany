import '../errors/app_exception.dart';
import '../errors/error_codes.dart';

/// Normalises and validates store URLs, and gates every outbound request.
///
/// Two rules are absolute:
///  * HTTPS only, except for explicitly-allowed loopback development hosts.
///  * A document may only be downloaded from the origin the agent is paired
///    with. A job that points somewhere else is refused, not followed.
abstract final class UrlValidator {
  /// Hosts for which plain HTTP is tolerated during development.
  static const Set<String> _loopbackHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
  };

  /// Cleans up whatever the operator typed into "Store URL".
  ///
  /// Accepts `example.com`, `example.com/`, `https://example.com/wp-admin/…`
  /// and returns `https://example.com` (preserving a subdirectory install path).
  /// Returns null when the input cannot be made into a usable URL.
  static String? normaliseStoreUrl(String input, {bool allowInsecure = false}) {
    var value = input.trim();
    if (value.isEmpty) return null;

    // Strip anything the operator may have pasted from their browser.
    value = value.replaceFirst(RegExp(r'#.*$'), '');
    value = value.replaceFirst(RegExp(r'\?.*$'), '');

    if (!value.contains('://')) value = 'https://$value';

    Uri uri;
    try {
      uri = Uri.parse(value);
    } catch (_) {
      return null;
    }
    if (uri.host.isEmpty) return null;
    if (!uri.host.contains('.') && !_loopbackHosts.contains(uri.host)) {
      // Reject bare words like "mystore" that are not resolvable hosts.
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (scheme == 'http' &&
        !allowInsecure &&
        !_loopbackHosts.contains(uri.host)) {
      return null;
    }

    // Drop the WordPress admin/REST tail if the operator pasted a deep link, but
    // keep a genuine subdirectory install ("/shop").
    var path = uri.path;
    for (final marker in <String>['/wp-admin', '/wp-json', '/wp-login.php']) {
      final index = path.indexOf(marker);
      if (index >= 0) {
        path = path.substring(0, index);
        break;
      }
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    final normalised = Uri(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: uri.hasPort && !_isDefaultPort(scheme, uri.port) ? uri.port : null,
      path: path,
    );
    return normalised.toString();
  }

  static bool _isDefaultPort(String scheme, int port) =>
      (scheme == 'https' && port == 443) || (scheme == 'http' && port == 80);

  /// True when [url] is safe to request at all.
  static bool isSecure(String url, {bool allowInsecure = false}) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme == 'https') return true;
      if (uri.scheme == 'http') {
        return allowInsecure || _loopbackHosts.contains(uri.host);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Whether [candidate] belongs to the same origin as [storeBaseUrl].
  ///
  /// Scheme, host and port must all match. A subdomain is *not* the same origin
  /// — `cdn.store.example` is refused for a store paired as `store.example`
  /// unless the plugin explicitly declares it (see [isAllowedDocumentUrl]).
  static bool isSameOrigin(String candidate, String storeBaseUrl) {
    try {
      final a = Uri.parse(candidate);
      final b = Uri.parse(storeBaseUrl);
      if (a.scheme.toLowerCase() != b.scheme.toLowerCase()) return false;
      if (a.host.toLowerCase() != b.host.toLowerCase()) return false;
      final portA = a.hasPort ? a.port : _defaultPort(a.scheme);
      final portB = b.hasPort ? b.port : _defaultPort(b.scheme);
      return portA == portB;
    } catch (_) {
      return false;
    }
  }

  static int _defaultPort(String scheme) =>
      scheme.toLowerCase() == 'http' ? 80 : 443;

  /// The gate every document URL passes through before a byte is fetched.
  ///
  /// Throws [DocumentException] rather than returning false so the reason
  /// reaches the job's error message and the log.
  static void assertAllowedDocumentUrl({
    required String url,
    required String storeBaseUrl,
    List<String> additionalAllowedOrigins = const <String>[],
    bool allowInsecure = false,
  }) {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (e) {
      throw DocumentException(
        userMessage: 'The document address supplied by your store is not valid.',
        code: ErrorCodes.documentUntrustedOrigin,
        technicalDetail: 'Unparseable URL: $url',
        retryable: false,
        cause: e,
      );
    }

    if (!uri.isAbsolute) {
      throw DocumentException(
        userMessage: 'The document address supplied by your store is not valid.',
        code: ErrorCodes.documentUntrustedOrigin,
        technicalDetail: 'Relative URL rejected: $url',
        retryable: false,
      );
    }

    if (!isSecure(url, allowInsecure: allowInsecure)) {
      throw DocumentException(
        userMessage:
            'The document could not be downloaded because your store offered it '
            'over an insecure connection.',
        code: ErrorCodes.documentUntrustedOrigin,
        technicalDetail: 'Non-HTTPS document URL rejected (${uri.scheme}).',
        retryable: false,
      );
    }

    if (isSameOrigin(url, storeBaseUrl)) return;
    for (final origin in additionalAllowedOrigins) {
      if (isSameOrigin(url, origin)) return;
    }

    throw DocumentException(
      userMessage:
          'The document could not be downloaded because it is hosted somewhere '
          'other than your store.',
      code: ErrorCodes.documentUntrustedOrigin,
      technicalDetail:
          'Origin ${uri.origin} is not the paired store or an approved origin.',
      retryable: false,
    );
  }

  /// A friendly host label for the UI ("store.example").
  static String displayHost(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}
