// A stand-in for a raw network printer, for testing without hardware.
//
// Real network printers speak the raw/JetDirect convention: the sender opens a
// TCP connection to port 9100, writes the document, and closes. There is no
// handshake and no response. That makes a convincing fake trivial — listen,
// read until the peer closes, and write what arrived to a file.
//
// Run it:
//
//   dart run tool/fake_printer.dart
//   dart run tool/fake_printer.dart --port 9100 --out ./captured
//
// Then add it in the agent as a network printer at 127.0.0.1:9100 and print.
// Each job lands in the output directory as its own file, and a summary of what
// arrived is printed to the console.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);

  if (options.showHelp) {
    stdout.writeln(_usage);
    return;
  }

  final outputDir = Directory(options.outputPath);
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  final ServerSocket server;
  try {
    server = await ServerSocket.bind(options.address, options.port);
  } on SocketException catch (e) {
    stderr
      ..writeln('Could not listen on ${options.address}:${options.port}.')
      ..writeln(e.message)
      ..writeln()
      ..writeln('Something else may already be using that port. Try --port 9101.');
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('Fake network printer listening on '
        '${server.address.address}:${server.port}')
    ..writeln('Saving jobs to ${outputDir.absolute.path}')
    ..writeln('Add it in the agent as: ${_addressHint(server)}')
    ..writeln('Press Ctrl+C to stop.')
    ..writeln();

  var jobNumber = 0;

  await for (final socket in server) {
    jobNumber++;
    unawaited(_handle(socket, jobNumber, outputDir, options));
  }
}

Future<void> _handle(
  Socket socket,
  int jobNumber,
  Directory outputDir,
  _Options options,
) async {
  final peer = '${socket.remoteAddress.address}:${socket.remotePort}';
  final started = DateTime.now();
  final chunks = <List<int>>[];

  try {
    // A raw printer reads until the sender closes. That close *is* the
    // end-of-document marker, which is why the agent half-closes rather than
    // leaving the socket open.
    await socket.forEach(chunks.add);
  } on SocketException catch (e) {
    stderr.writeln('Job $jobNumber: connection error from $peer — ${e.message}');
  } finally {
    socket.destroy();
  }

  final bytes = chunks.expand((List<int> c) => c).toList(growable: false);
  final elapsed = DateTime.now().difference(started);

  if (bytes.isEmpty) {
    stdout.writeln('Job $jobNumber from $peer: connected but sent nothing '
        '(this is what a reachability probe looks like)');
    return;
  }

  final stamp = started
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final file = File('${outputDir.path}/job-$stamp.bin');
  await file.writeAsBytes(bytes);

  stdout
    ..writeln('Job $jobNumber from $peer')
    ..writeln('  bytes   : ${bytes.length}')
    ..writeln('  took    : ${elapsed.inMilliseconds} ms')
    ..writeln('  kind    : ${_sniff(bytes)}')
    ..writeln('  saved   : ${file.path}');

  if (options.showBody) {
    stdout
      ..writeln('  ------- content -------')
      ..writeln(_preview(bytes))
      ..writeln('  -----------------------');
  }

  stdout.writeln();
}

/// Identifies the payload from its first bytes, the same way a real device
/// decides how to interpret what it was handed.
String _sniff(List<int> bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(<int>[0x25, 0x50, 0x44, 0x46])) return 'PDF';
  if (startsWith(<int>[0x89, 0x50, 0x4E, 0x47])) return 'PNG';
  if (startsWith(<int>[0xFF, 0xD8, 0xFF])) return 'JPEG';
  if (startsWith(<int>[0x1B, 0x40])) return 'ESC/POS (ESC @ initialise)';
  if (startsWith(<int>[0x5E, 0x58, 0x41])) return 'ZPL (^XA)';
  if (startsWith(<int>[0x1B, 0x25, 0x2D])) return 'PCL';
  if (startsWith(<int>[0x25, 0x21])) return 'PostScript';

  final printable = bytes
      .take(512)
      .where((int b) => b == 9 || b == 10 || b == 13 || (b >= 32 && b < 127))
      .length;
  final sampled = bytes.length < 512 ? bytes.length : 512;

  if (sampled > 0 && printable / sampled > 0.9) {
    final text = utf8.decode(bytes.take(512).toList(), allowMalformed: true);
    if (text.trimLeft().toLowerCase().startsWith('<!doctype') ||
        text.trimLeft().toLowerCase().startsWith('<html')) {
      return 'HTML';
    }
    return 'plain text';
  }

  return 'binary';
}

String _preview(List<int> bytes, {int limit = 2000}) {
  final text = utf8.decode(
    bytes.take(limit).toList(),
    allowMalformed: true,
  );

  final rendered = text
      .split('\n')
      .map((String line) => '  | ${line.trimRight()}')
      .join('\n');

  return bytes.length > limit ? '$rendered\n  | … truncated' : rendered;
}

String _addressHint(ServerSocket server) {
  final address = server.address.address;
  final host = address == '0.0.0.0' || address == '::' ? '127.0.0.1' : address;
  return '$host:${server.port}';
}

class _Options {
  const _Options({
    required this.port,
    required this.address,
    required this.outputPath,
    required this.showBody,
    required this.showHelp,
  });

  final int port;
  final String address;
  final String outputPath;
  final bool showBody;
  final bool showHelp;

  static _Options parse(List<String> arguments) {
    var port = 9100;
    var address = '0.0.0.0';
    var output = 'captured-jobs';
    var showBody = true;
    var help = false;

    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--port':
        case '-p':
          if (i + 1 < arguments.length) {
            port = int.tryParse(arguments[++i]) ?? port;
          }
        case '--address':
        case '-a':
          if (i + 1 < arguments.length) address = arguments[++i];
        case '--out':
        case '-o':
          if (i + 1 < arguments.length) output = arguments[++i];
        case '--quiet':
        case '-q':
          showBody = false;
        case '--help':
        case '-h':
          help = true;
      }
    }

    return _Options(
      port: port,
      address: address,
      outputPath: output,
      showBody: showBody,
      showHelp: help,
    );
  }
}

const String _usage = '''
Fake raw network printer.

Listens on a TCP port and treats anything written to it as one print job,
exactly as a JetDirect/raw printer on port 9100 does.

  dart run tool/fake_printer.dart [options]

Options:
  -p, --port <n>       Port to listen on (default 9100)
  -a, --address <ip>   Address to bind (default 0.0.0.0, all interfaces)
  -o, --out <dir>      Where to save received jobs (default ./captured-jobs)
  -q, --quiet          Do not print job contents to the console
  -h, --help           Show this message

Then in the agent, add a network printer at 127.0.0.1:9100.
''';
