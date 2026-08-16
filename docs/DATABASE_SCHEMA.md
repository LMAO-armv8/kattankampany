# Local database schema

SQLite via `sqflite_common_ffi`. File: `%APPDATA%\WooCommercePrintAgent\agent.db`.
Journal mode WAL, `foreign_keys=ON`, `busy_timeout=5000`.

Migrations live in `lib/core/storage/migrations.dart` as an ordered list; the current
schema version is `1`. Migrations are forward-only and additive.

---

## `stores`

One row per paired WooCommerce installation. Multi-store is not exposed in the UI yet,
but the schema does not prevent it.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | local UUID |
| `base_url` | TEXT NOT NULL UNIQUE | normalised, always `https://host[/path]` |
| `store_name` | TEXT | reported by the server |
| `api_namespace` | TEXT NOT NULL DEFAULT 'wpm/v1' | |
| `is_active` | INTEGER NOT NULL DEFAULT 1 | exactly one active today |
| `created_at` | INTEGER NOT NULL | epoch ms |
| `updated_at` | INTEGER NOT NULL | |

## `agents`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | local UUID |
| `store_id` | TEXT NOT NULL REFERENCES stores(id) ON DELETE CASCADE | |
| `server_agent_id` | TEXT | id assigned by the plugin |
| `name` | TEXT NOT NULL | operator-chosen |
| `machine_name` | TEXT NOT NULL | |
| `os_description` | TEXT NOT NULL | |
| `app_version` | TEXT NOT NULL | |
| `status` | TEXT NOT NULL DEFAULT 'unregistered' | unregistered / active / disabled / revoked |
| `last_sync_at` | INTEGER | epoch ms |
| `last_heartbeat_at` | INTEGER | |
| `metadata_json` | TEXT NOT NULL DEFAULT '{}' | forward-compatibility bag |
| `created_at` / `updated_at` | INTEGER NOT NULL | |

Index: `idx_agents_store` on `(store_id)`.

**Tokens are not stored here.** They live in DPAPI-encrypted blobs under
`%APPDATA%\WooCommercePrintAgent\credentials\<agentId>.bin`.

## `printers`

Locally discovered devices plus operator configuration.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | local UUID |
| `printer_key` | TEXT NOT NULL UNIQUE | the Windows printer name — the stable cross-system identifier |
| `display_name` | TEXT NOT NULL | |
| `driver_name` | TEXT | |
| `port_name` | TEXT | |
| `manufacturer` | TEXT | best-effort, parsed from driver |
| `model` | TEXT | best-effort |
| `connection_type` | TEXT | usb / network / bluetooth / virtual / unknown |
| `is_default` | INTEGER NOT NULL DEFAULT 0 | |
| `is_enabled` | INTEGER NOT NULL DEFAULT 1 | operator can hide a printer from the agent |
| `last_status` | TEXT NOT NULL DEFAULT 'unknown' | |
| `last_status_at` | INTEGER | |
| `capabilities_json` | TEXT NOT NULL DEFAULT '[]' | |
| `paper_sizes_json` | TEXT NOT NULL DEFAULT '[]' | |
| `default_profile_id` | TEXT REFERENCES print_profiles(id) ON DELETE SET NULL | |
| `created_at` / `updated_at` | INTEGER NOT NULL | |

## `print_profiles`

Generic, printer-independent page setups. Seeded with `A4 Document`, `Letter Document`,
`4x6 Label`, `80mm Receipt` — none of which name a vendor.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `name` | TEXT NOT NULL UNIQUE | |
| `paper_size` | TEXT NOT NULL | named size or `custom` |
| `width_mm` / `height_mm` | REAL | required when `paper_size='custom'` |
| `orientation` | TEXT NOT NULL DEFAULT 'portrait' | |
| `scaling` | TEXT NOT NULL DEFAULT 'fit' | none / fit / fill / actual |
| `margin_top_mm` … `margin_left_mm` | REAL NOT NULL DEFAULT 0 | |
| `copies` | INTEGER NOT NULL DEFAULT 1 | |
| `quality` | TEXT NOT NULL DEFAULT 'normal' | |
| `color` | INTEGER NOT NULL DEFAULT 1 | |
| `duplex` | TEXT NOT NULL DEFAULT 'simplex' | |
| `strategy` | TEXT NOT NULL DEFAULT 'auto' | auto / spooler / raw / pdf / image / escpos |
| `is_builtin` | INTEGER NOT NULL DEFAULT 0 | built-ins cannot be deleted |
| `created_at` / `updated_at` | INTEGER NOT NULL | |

## `print_jobs`

The authoritative local queue. Survives restarts.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | local UUID |
| `store_id` | TEXT NOT NULL REFERENCES stores(id) ON DELETE CASCADE | |
| `server_job_id` | TEXT NOT NULL | **UNIQUE with store_id** — the duplicate guard |
| `order_id` | TEXT | |
| `order_reference` | TEXT | human label, e.g. `#5591` |
| `document_type` | TEXT NOT NULL | pdf/png/jpeg/html/text/raw |
| `document_url` | TEXT | |
| `document_filename` | TEXT | |
| `document_sha256` | TEXT | |
| `document_size_bytes` | INTEGER | |
| `document_expires_at` | INTEGER | |
| `local_file_path` | TEXT | set after successful download |
| `requested_printer_key` | TEXT | from the server; may be null |
| `resolved_printer_key` | TEXT | what the agent actually used |
| `allow_fallback` | INTEGER NOT NULL DEFAULT 0 | |
| `profile_json` | TEXT NOT NULL DEFAULT '{}' | the effective PrintProfile |
| `copies` | INTEGER NOT NULL DEFAULT 1 | |
| `priority` | INTEGER NOT NULL DEFAULT 0 | higher first |
| `status` | TEXT NOT NULL | see state machine below |
| `attempt_count` | INTEGER NOT NULL DEFAULT 0 | |
| `max_attempts` | INTEGER NOT NULL DEFAULT 4 | snapshot of policy at insert |
| `next_attempt_at` | INTEGER | engine ignores rows until this passes |
| `lease_owner` | TEXT | process UUID that owns the print |
| `lease_expires_at` | INTEGER | |
| `spooler_job_id` | INTEGER | Windows spool job id when known |
| `error_code` | TEXT | |
| `error_message` | TEXT | user-safe text |
| `error_detail` | TEXT | technical, shown only in logs/diagnostics |
| `created_at` | INTEGER NOT NULL | when the agent learned of it |
| `claimed_at` / `started_at` / `completed_at` | INTEGER | |
| `reported_at` | INTEGER | when the terminal state reached the server |
| `metadata_json` | TEXT NOT NULL DEFAULT '{}' | |

Indexes:

```sql
CREATE UNIQUE INDEX idx_jobs_server_unique ON print_jobs(store_id, server_job_id);
CREATE INDEX idx_jobs_status            ON print_jobs(status);
CREATE INDEX idx_jobs_ready             ON print_jobs(status, next_attempt_at, priority DESC, created_at);
CREATE INDEX idx_jobs_completed_at      ON print_jobs(completed_at);
CREATE INDEX idx_jobs_unreported        ON print_jobs(reported_at) WHERE reported_at IS NULL;
```

`idx_jobs_server_unique` is the single most important line in the schema.

### Job state machine

```
            ┌──────────┐
  discovered│  queued  │◄──────────── retry (next_attempt_at set)
            └────┬─────┘
                 │ claim ok
            ┌────▼──────┐
            │ claimed   │
            └────┬──────┘
                 │ download + validate + resolve printer
            ┌────▼──────┐
            │downloading│──── failure ─┐
            └────┬──────┘              │
                 │                     │
            ┌────▼──────┐              │
            │ printing  │──── failure ─┤
            └────┬──────┘              │
                 │ spooled ok          │
            ┌────▼──────┐        ┌─────▼─────┐
            │ completed │        │  failed   │
            └───────────┘        └─────┬─────┘
                                       │ attempts exhausted
                                 ┌─────▼──────┐
                                 │ failed     │ (terminal, operator visible)
                                 └────────────┘

  any non-terminal ──cancel──► cancelled
  printing at startup with foreign/expired lease ──► interrupted (operator decides)
```

Statuses: `queued`, `claimed`, `downloading`, `printing`, `completed`, `failed`,
`cancelled`, `interrupted`.

## `print_history`

Completed/failed jobs are **not** deleted from `print_jobs` immediately; a daily
maintenance pass copies terminal rows older than `historyRetentionDays` (default 30)
into `print_history` in condensed form and deletes them from `print_jobs`. History is
itself capped at `maxHistoryRows` (default 20 000) — this is the unbounded-growth guard.

| Column | Type |
|---|---|
| `id` TEXT PK, `store_id` TEXT, `server_job_id` TEXT, `order_reference` TEXT, `document_type` TEXT, `printer_key` TEXT, `status` TEXT, `attempt_count` INTEGER, `error_code` TEXT, `error_message` TEXT, `created_at` INTEGER, `completed_at` INTEGER | |

Index: `idx_history_completed_at` on `(completed_at DESC)`.

## `settings`

Key/value, one row per setting. Typed accessors live in `SettingsRepository`.

| Column | Type |
|---|---|
| `key` TEXT PK, `value` TEXT NOT NULL, `updated_at` INTEGER NOT NULL |

## `logs`

Recent structured log records, for the in-app log viewer. The durable log is the rotating
file; this table is a bounded mirror (`maxLogRows`, default 5 000, trimmed on insert).

| Column | Type |
|---|---|
| `id` INTEGER PK AUTOINCREMENT, `timestamp` INTEGER NOT NULL, `level` TEXT NOT NULL, `category` TEXT NOT NULL, `message` TEXT NOT NULL, `context_json` TEXT, `error` TEXT, `stack_trace` TEXT |

Index: `idx_logs_ts` on `(timestamp DESC)`, `idx_logs_level` on `(level)`.

## `idempotency_keys`

Client-side record of state-changing calls that have not yet been confirmed, so a report
interrupted by a crash is replayed exactly once on next start.

| Column | Type |
|---|---|
| `key` TEXT PK, `job_id` TEXT NOT NULL, `action` TEXT NOT NULL, `payload_json` TEXT NOT NULL, `created_at` INTEGER NOT NULL, `confirmed_at` INTEGER |

Index: `idx_idem_pending` on `(confirmed_at)`.
