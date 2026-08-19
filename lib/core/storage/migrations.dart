import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Forward-only, additive schema migrations.
///
/// To change the schema: append a new [Migration] with `version: n + 1` and
/// bump [latestVersion]. Never edit an existing migration — installed agents
/// have already run it.
class Migration {
  const Migration({required this.version, required this.statements});

  final int version;
  final List<String> statements;
}

const int latestVersion = 3;

const List<Migration> migrations = <Migration>[
  Migration(
    version: 1,
    statements: <String>[
      '''
      CREATE TABLE stores (
        id             TEXT PRIMARY KEY,
        base_url       TEXT NOT NULL UNIQUE,
        store_name     TEXT,
        api_namespace  TEXT NOT NULL DEFAULT 'wpm/v1',
        is_active      INTEGER NOT NULL DEFAULT 1,
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
      )
      ''',
      '''
      CREATE TABLE agents (
        id                TEXT PRIMARY KEY,
        store_id          TEXT NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
        server_agent_id   TEXT,
        name              TEXT NOT NULL,
        machine_name      TEXT NOT NULL,
        os_description    TEXT NOT NULL,
        app_version       TEXT NOT NULL,
        status            TEXT NOT NULL DEFAULT 'unregistered',
        last_sync_at      INTEGER,
        last_heartbeat_at INTEGER,
        metadata_json     TEXT NOT NULL DEFAULT '{}',
        created_at        INTEGER NOT NULL,
        updated_at        INTEGER NOT NULL
      )
      ''',
      'CREATE INDEX idx_agents_store ON agents(store_id)',
      '''
      CREATE TABLE print_profiles (
        id             TEXT PRIMARY KEY,
        name           TEXT NOT NULL UNIQUE,
        paper_size     TEXT NOT NULL,
        width_mm       REAL,
        height_mm      REAL,
        orientation    TEXT NOT NULL DEFAULT 'portrait',
        scaling        TEXT NOT NULL DEFAULT 'fit',
        margin_top_mm    REAL NOT NULL DEFAULT 0,
        margin_right_mm  REAL NOT NULL DEFAULT 0,
        margin_bottom_mm REAL NOT NULL DEFAULT 0,
        margin_left_mm   REAL NOT NULL DEFAULT 0,
        copies         INTEGER NOT NULL DEFAULT 1,
        quality        TEXT NOT NULL DEFAULT 'normal',
        color          INTEGER NOT NULL DEFAULT 1,
        duplex         TEXT NOT NULL DEFAULT 'simplex',
        strategy       TEXT NOT NULL DEFAULT 'auto',
        is_builtin     INTEGER NOT NULL DEFAULT 0,
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
      )
      ''',
      '''
      CREATE TABLE printers (
        id                 TEXT PRIMARY KEY,
        printer_key        TEXT NOT NULL UNIQUE,
        display_name       TEXT NOT NULL,
        driver_name        TEXT,
        port_name          TEXT,
        manufacturer       TEXT,
        model              TEXT,
        connection_type    TEXT NOT NULL DEFAULT 'unknown',
        is_default         INTEGER NOT NULL DEFAULT 0,
        is_enabled         INTEGER NOT NULL DEFAULT 1,
        last_status        TEXT NOT NULL DEFAULT 'unknown',
        last_status_at     INTEGER,
        capabilities_json  TEXT NOT NULL DEFAULT '[]',
        paper_sizes_json   TEXT NOT NULL DEFAULT '[]',
        default_profile_id TEXT REFERENCES print_profiles(id) ON DELETE SET NULL,
        created_at         INTEGER NOT NULL,
        updated_at         INTEGER NOT NULL
      )
      ''',
      '''
      CREATE TABLE print_jobs (
        id                    TEXT PRIMARY KEY,
        store_id              TEXT NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
        server_job_id         TEXT NOT NULL,
        order_id              TEXT,
        order_reference       TEXT,
        document_type         TEXT NOT NULL,
        document_url          TEXT,
        document_filename     TEXT,
        document_sha256       TEXT,
        document_size_bytes   INTEGER,
        document_expires_at   INTEGER,
        local_file_path       TEXT,
        requested_printer_key TEXT,
        resolved_printer_key  TEXT,
        allow_fallback        INTEGER NOT NULL DEFAULT 0,
        profile_json          TEXT NOT NULL DEFAULT '{}',
        copies                INTEGER NOT NULL DEFAULT 1,
        priority              INTEGER NOT NULL DEFAULT 0,
        status                TEXT NOT NULL,
        attempt_count         INTEGER NOT NULL DEFAULT 0,
        max_attempts          INTEGER NOT NULL DEFAULT 4,
        next_attempt_at       INTEGER,
        lease_owner           TEXT,
        lease_expires_at      INTEGER,
        spooler_job_id        INTEGER,
        error_code            TEXT,
        error_message         TEXT,
        error_detail          TEXT,
        created_at            INTEGER NOT NULL,
        claimed_at            INTEGER,
        started_at            INTEGER,
        completed_at          INTEGER,
        reported_at           INTEGER,
        metadata_json         TEXT NOT NULL DEFAULT '{}'
      )
      ''',
      // The duplicate-print guard. Everything else in the pipeline is defence
      // in depth; this constraint is the one the database itself enforces.
      'CREATE UNIQUE INDEX idx_jobs_server_unique ON print_jobs(store_id, server_job_id)',
      'CREATE INDEX idx_jobs_status ON print_jobs(status)',
      'CREATE INDEX idx_jobs_ready ON print_jobs(status, next_attempt_at, priority DESC, created_at)',
      'CREATE INDEX idx_jobs_completed_at ON print_jobs(completed_at)',
      '''
      CREATE TABLE print_history (
        id              TEXT PRIMARY KEY,
        store_id        TEXT,
        server_job_id   TEXT,
        order_reference TEXT,
        document_type   TEXT,
        printer_key     TEXT,
        status          TEXT NOT NULL,
        attempt_count   INTEGER NOT NULL DEFAULT 0,
        error_code      TEXT,
        error_message   TEXT,
        created_at      INTEGER NOT NULL,
        completed_at    INTEGER
      )
      ''',
      'CREATE INDEX idx_history_completed_at ON print_history(completed_at DESC)',
      '''
      CREATE TABLE settings (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
      ''',
      '''
      CREATE TABLE logs (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp    INTEGER NOT NULL,
        level        TEXT NOT NULL,
        category     TEXT NOT NULL,
        message      TEXT NOT NULL,
        context_json TEXT,
        error        TEXT,
        stack_trace  TEXT
      )
      ''',
      'CREATE INDEX idx_logs_ts ON logs(timestamp DESC)',
      'CREATE INDEX idx_logs_level ON logs(level)',
      '''
      CREATE TABLE idempotency_keys (
        key          TEXT PRIMARY KEY,
        job_id       TEXT NOT NULL,
        action       TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at   INTEGER NOT NULL,
        confirmed_at INTEGER
      )
      ''',
      'CREATE INDEX idx_idem_pending ON idempotency_keys(confirmed_at)',
    ],
  ),
  Migration(
    version: 2,
    statements: <String>[
      // The host or address behind a network printer port, read from the
      // Standard TCP/IP port monitor at discovery time. Diagnostic only — jobs
      // are always addressed by printer_key through the spooler — but it is the
      // first thing a support engineer asks for when a network printer stops
      // answering.
      'ALTER TABLE printers ADD COLUMN host TEXT',
    ],
  ),
  Migration(
    version: 3,
    statements: <String>[
      // Where the printed document was kept, so an operator can open what
      // actually came out of the printer rather than taking the log's word for
      // it. Null once the retention sweep has removed the file, or for a job
      // that failed before the document was fetched.
      'ALTER TABLE print_history ADD COLUMN document_path TEXT',
      'ALTER TABLE print_history ADD COLUMN document_filename TEXT',
    ],
  ),
];

Future<void> applyMigrations(
  DatabaseExecutor db, {
  required int from,
  required int to,
}) async {
  for (final migration in migrations) {
    if (migration.version <= from || migration.version > to) continue;
    for (final statement in migration.statements) {
      await db.execute(statement);
    }
  }
}
