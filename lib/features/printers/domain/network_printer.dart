import 'dart:convert';

/// A printer the agent talks to directly over TCP, without Windows.
///
/// Windows' own printer list only contains devices someone has *installed*, and
/// reading it requires the Print Spooler service. Neither is a given: a locked
/// down or security-hardened machine frequently has the spooler disabled, and a
/// network printer on the shop floor often has no driver installed at all.
///
/// A network printer here is therefore addressed by host and port and spoken to
/// directly. Port 9100 is the near-universal "raw"/JetDirect convention: open a
/// socket, write the document bytes, close it. That is the whole protocol, which
/// is why it works with everything from a thermal receipt printer to a laser.
///
/// The trade-off is honest: there is no driver in the path, so the bytes must
/// already be in a language the device understands (ESC/POS, ZPL, PCL,
/// PostScript). The agent does not transcode.
class NetworkPrinter {
  const NetworkPrinter({
    required this.name,
    required this.host,
    this.port = defaultRawPort,
    this.enabled = true,
    this.description,
  });

  /// The port virtually every raw/JetDirect capable printer listens on.
  static const int defaultRawPort = 9100;

  /// Shown to the operator, and used to build the stable key.
  final String name;

  /// Hostname or IP address.
  final String host;

  final int port;
  final bool enabled;
  final String? description;

  /// The identifier used everywhere else — the database, heartbeats, and the
  /// server's `printer_key`.
  ///
  /// Derived from host and port rather than the name so that renaming a printer
  /// in the UI does not orphan queued jobs that were routed to it.
  String get printerKey => 'net://$host:$port';

  bool get isValid => host.trim().isNotEmpty && port > 0 && port <= 65535;

  NetworkPrinter copyWith({
    String? name,
    String? host,
    int? port,
    bool? enabled,
    String? description,
  }) =>
      NetworkPrinter(
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        enabled: enabled ?? this.enabled,
        description: description ?? this.description,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'host': host,
        'port': port,
        'enabled': enabled,
        if (description != null) 'description': description,
      };

  static NetworkPrinter? fromJson(Map<String, dynamic> json) {
    final host = (json['host'] as String?)?.trim() ?? '';
    if (host.isEmpty) return null;

    final port = (json['port'] as num?)?.toInt() ?? defaultRawPort;
    final name = (json['name'] as String?)?.trim();

    return NetworkPrinter(
      name: name == null || name.isEmpty ? '$host:$port' : name,
      host: host,
      port: port < 1 || port > 65535 ? defaultRawPort : port,
      enabled: json['enabled'] as bool? ?? true,
      description: json['description'] as String?,
    );
  }

  /// Parses `host`, `host:port` or `net://host:port`.
  ///
  /// Accepting the bare forms matters: an operator reading an address off a
  /// printer's configuration page types `192.168.1.50`, not a URI.
  static NetworkPrinter? parse(String input, {String? name}) {
    var text = input.trim();
    if (text.isEmpty) return null;

    if (text.startsWith('net://')) text = text.substring(6);

    // Bracketed IPv6, e.g. [fe80::1]:9100
    if (text.startsWith('[')) {
      final close = text.indexOf(']');
      if (close < 0) return null;
      final host = text.substring(1, close);
      final rest = text.substring(close + 1);
      final port = rest.startsWith(':')
          ? int.tryParse(rest.substring(1)) ?? defaultRawPort
          : defaultRawPort;
      return NetworkPrinter(
        name: name?.trim().isNotEmpty == true ? name!.trim() : '$host:$port',
        host: host,
        port: port,
      );
    }

    final colon = text.lastIndexOf(':');
    var host = text;
    var port = defaultRawPort;

    if (colon > 0) {
      final maybePort = int.tryParse(text.substring(colon + 1));
      if (maybePort != null && maybePort > 0 && maybePort <= 65535) {
        host = text.substring(0, colon);
        port = maybePort;
      }
    }

    if (host.isEmpty) return null;

    return NetworkPrinter(
      name: name?.trim().isNotEmpty == true ? name!.trim() : '$host:$port',
      host: host,
      port: port,
    );
  }

  @override
  String toString() => 'NetworkPrinter($name, $host:$port)';

  @override
  bool operator ==(Object other) =>
      other is NetworkPrinter && other.printerKey == printerKey;

  @override
  int get hashCode => printerKey.hashCode;

  String encode() => jsonEncode(toJson());
}
