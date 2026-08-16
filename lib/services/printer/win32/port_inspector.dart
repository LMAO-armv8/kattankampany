import '../../../core/platform/win32_registry.dart';
import '../../../features/printers/domain/printer_status.dart';

/// Resolves the transport behind a Windows printer port.
///
/// `EnumPrintersW` reports a port *name* and nothing about how that port is
/// wired, so the port name is all there is to go on. That is mostly enough —
/// `USB001`, `LPT1:`, `WSD-…` are unambiguous — but two common cases are not:
///
///  * **Bluetooth printers.** Windows exposes a paired Bluetooth printer over a
///    virtual serial port, so it arrives as `COM5` and is indistinguishable from
///    a genuine RS-232 printer by name alone. The mapping from COM port to
///    underlying device lives in `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, where a
///    Bluetooth link appears as `\Device\BthModem0`.
///
///  * **Network printers.** A `Standard TCP/IP Port` may be named anything the
///    person who created it typed. The host or address it actually points at is
///    stored under the port monitor's key.
///
/// Both are read-only lookups against `HKEY_LOCAL_MACHINE`, which needs no
/// elevation. Everything degrades to the name-only classification when the
/// registry is unreadable or the machine has no Bluetooth stack.
///
/// A note on Wi-Fi: Windows does **not** record whether a network printer is
/// reached over Wi-Fi or Ethernet, and it is not discoverable from the host —
/// a printer at `192.168.1.50` looks identical either way. Both therefore
/// classify as [PrinterConnectionType.network]. Inventing the distinction would
/// mean sending a guess to the server as fact.
class PortInspector {
  const PortInspector({
    Set<String> bluetoothComPorts = const <String>{},
    Map<String, String> portHosts = const <String, String>{},
  })  : _bluetoothComPorts = bluetoothComPorts,
        _portHosts = portHosts;

  /// COM port names known to be Bluetooth links, upper-cased (`{'COM5'}`).
  final Set<String> _bluetoothComPorts;

  /// Port name (upper-cased) to the host or address behind it.
  final Map<String, String> _portHosts;

  static const String _serialCommKey = r'HARDWARE\DEVICEMAP\SERIALCOMM';
  static const String _tcpPortsKey =
      r'SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports';

  /// Reads the machine's port topology once, for reuse across a whole discovery
  /// pass. Discovery enumerates every printer, and re-reading the registry per
  /// printer would be wasteful.
  factory PortInspector.load({Iterable<String> portNames = const <String>[]}) {
    final bluetooth = <String>{};
    final hosts = <String, String>{};

    // SERIALCOMM maps a device path to the COM name it was given, e.g.
    // {'\Device\BthModem0': 'COM5', '\Device\Serial0': 'COM1'}.
    final serialComm = Win32Registry.readStringValues(
      subKey: _serialCommKey,
      hive: RegistryConstants.hkeyLocalMachine,
    );
    serialComm.forEach((String devicePath, String comName) {
      final device = devicePath.toUpperCase();
      if (device.contains('BTHMODEM') || device.contains('BLUETOOTH')) {
        bluetooth.add(comName.toUpperCase());
      }
    });

    // The TCP/IP port monitor keys the host by port name, so each port is
    // looked up directly rather than enumerating subkeys.
    for (final port in portNames) {
      if (port.isEmpty) continue;
      final host = Win32Registry.readString(
            subKey: '$_tcpPortsKey\\$port',
            valueName: 'HostName',
            hive: RegistryConstants.hkeyLocalMachine,
          ) ??
          Win32Registry.readString(
            subKey: '$_tcpPortsKey\\$port',
            valueName: 'IPAddress',
            hive: RegistryConstants.hkeyLocalMachine,
          );
      if (host != null && host.isNotEmpty) {
        hosts[port.toUpperCase()] = host;
      }
    }

    return PortInspector(bluetoothComPorts: bluetooth, portHosts: hosts);
  }

  /// The host or address behind a network port, when one is recorded.
  String? hostFor(String? port) {
    if (port == null || port.isEmpty) return null;
    return _portHosts[port.toUpperCase()];
  }

  /// Best available classification for a port.
  ///
  /// [driver] and [displayName] are consulted only as a last resort, for devices
  /// whose port name says nothing useful — some vendor Bluetooth drivers install
  /// on a port called `PRN` or similar.
  PrinterConnectionType classify({
    String? port,
    String? driver,
    String? displayName,
    bool isVirtual = false,
  }) {
    final value = (port ?? '').toUpperCase();

    // Virtual devices first: a PDF writer on `PORTPROMPT:` must not be reported
    // as a real transport.
    if (_looksVirtualPort(value) || (isVirtual && value.isEmpty)) {
      return PrinterConnectionType.virtual;
    }

    if (value.startsWith('USB')) return PrinterConnectionType.usb;

    // Bluetooth before serial: a Bluetooth printer *is* a COM port.
    if (value.startsWith('BTH') ||
        value.contains('BLUETOOTH') ||
        _bluetoothComPorts.contains(_comName(value))) {
      return PrinterConnectionType.bluetooth;
    }

    if (value.startsWith('WSD') ||
        value.startsWith('IP_') ||
        value.startsWith(r'\\') ||
        value.contains('TCP') ||
        _portHosts.containsKey(value) ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(value)) {
      return PrinterConnectionType.network;
    }

    if (value.startsWith('COM')) return PrinterConnectionType.serial;
    if (value.startsWith('LPT')) return PrinterConnectionType.parallel;

    // Nothing in the port name. Fall back to the driver and product name, which
    // frequently carry the word outright.
    final hint = '${driver ?? ''} ${displayName ?? ''}'.toUpperCase();
    if (hint.contains('BLUETOOTH')) return PrinterConnectionType.bluetooth;
    if (hint.contains('WI-FI') ||
        hint.contains('WIFI') ||
        hint.contains('WIRELESS') ||
        hint.contains('NETWORK')) {
      return PrinterConnectionType.network;
    }

    if (isVirtual) return PrinterConnectionType.virtual;
    return PrinterConnectionType.unknown;
  }

  /// `COM5:` and `COM5` are both written by different Windows components.
  static String _comName(String port) =>
      port.endsWith(':') ? port.substring(0, port.length - 1) : port;

  static bool _looksVirtualPort(String port) =>
      port.contains('PORTPROMPT') ||
      port.contains('NUL:') ||
      port.startsWith('FILE:') ||
      port.contains('SHRFAX') ||
      port.contains('XPSPORT') ||
      port.contains('ONENOTE');
}
