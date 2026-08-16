import '../api/dto/print_job_dto.dart';

/// Where new jobs come from.
///
/// Today there is one implementation ([PollingJobSource]); the interface exists
/// so a push transport — a WebSocket, or a cloud relay — can be dropped in
/// without the queue engine or the UI noticing. That is the whole reason
/// fetching and processing are separate services.
abstract class JobSource {
  /// Human-readable name, shown on the Diagnostics screen.
  String get name;

  /// Returns jobs the agent may claim. An empty list is a normal result.
  Future<List<RemotePrintJob>> fetch({int limit});

  /// Whether this source needs the agent to poll it.
  bool get requiresPolling;
}
