# WooCommerce Print Management API — Integration Contract

This is the contract the Flutter agent implements. It is written so a WordPress plugin
developer can build the server side without reading Dart, and so the agent can be
pointed at any conforming implementation.

* **Base path:** `https://<store>/wp-json/wpm/v1/`
* **Transport:** HTTPS only. TLS validation is always on.
* **Encoding:** JSON, UTF-8.
* **Versioning:** the version segment (`v1`) is part of the base path. The agent sends
  `X-Agent-Api-Version: 1` and will refuse to talk to a server advertising a major
  version it does not understand.

## Common headers

| Header | Direction | Notes |
|---|---|---|
| `Authorization: Bearer <token>` | → server | On every call except pairing start/poll. |
| `X-Agent-Id` | → server | Agent UUID, present once registered. |
| `X-Agent-Version` | → server | Application semantic version. |
| `X-Request-Id` | → server | Random per request; echoed in logs both sides. |
| `Idempotency-Key` | → server | On every state-changing job call. See §6. |
| `Retry-After` | ← server | Honoured on 429 and 503. |

## Common error envelope

Non-2xx responses should use the WordPress REST shape:

```json
{ "code": "wpm_job_already_claimed", "message": "Job already claimed by another agent.", "data": { "status": 409 } }
```

The agent maps status codes as follows:

| Status | Meaning to the agent | Behaviour |
|---|---|---|
| 200/201 | success | continue |
| 204 | success, no body | continue |
| 400 | malformed request | log, fail job, no retry |
| 401 | token invalid/expired | stop sync, require re-pair |
| 403 | agent disabled or revoked | stop sync, show message |
| 404 | job/endpoint gone | mark job cancelled locally, no retry |
| 409 | job claimed elsewhere / state conflict | drop job locally, no retry, not an error |
| 410 | document expired | fail job with document error |
| 422 | validation | fail job, no retry |
| 429 | rate limited | honour `Retry-After`, widen poll interval |
| 5xx | server fault | retry with backoff |

---

## 1. Pairing (no admin credentials)

The agent never asks for a WordPress username or password.

```
POST /wpm/v1/pairing/start          (unauthenticated)
```

Request:
```json
{
  "agent_name": "Warehouse PC",
  "machine_name": "WH-01",
  "os": "Windows 11 Pro 23H2 (10.0.22631)",
  "app_version": "1.0.0",
  "public_key_fingerprint": "b1946ac9…",
  "requested_scopes": ["print_jobs:read", "print_jobs:write", "printers:write"]
}
```

Response `201`:
```json
{
  "pairing_id": "pr_9f2c…",
  "pairing_code": "K3F-92H-QD7",
  "verification_url": "https://store.example/wp-admin/admin.php?page=wpm-agents&pair=pr_9f2c",
  "expires_at": "2026-08-15T10:12:00Z",
  "poll_interval_seconds": 3
}
```

The agent shows `pairing_code` and `verification_url`. An administrator, already
logged in to wp-admin, approves the request and names/authorises the device.

```
GET /wpm/v1/pairing/{pairing_id}    (unauthenticated, rate limited)
```

Response while waiting `200`:
```json
{ "status": "pending", "expires_at": "2026-08-15T10:12:00Z" }
```

Response once approved `200`:
```json
{
  "status": "approved",
  "agent": {
    "id": "ag_71ab…",
    "name": "Warehouse PC",
    "store_name": "Example Store",
    "store_url": "https://store.example"
  },
  "credentials": {
    "token": "wpm_at_…",
    "token_type": "Bearer",
    "expires_at": null,
    "refresh_token": "wpm_rt_…"
  }
}
```

Other terminal statuses: `denied`, `expired`. The agent stops polling on any terminal
status. The pairing code is single-use and short-lived (recommended TTL ≤ 10 minutes).

**Server requirements:** rate-limit `pairing/start` per IP; rate-limit `pairing/{id}`
polling; never return credentials more than once; bind the approval to a logged-in
administrator with a capability check (`manage_woocommerce` or a dedicated capability).

### Token refresh (optional)

```
POST /wpm/v1/pairing/refresh
{ "refresh_token": "wpm_rt_…" }
→ 200 { "token": "wpm_at_…", "expires_at": "…", "refresh_token": "wpm_rt_…" }
```

If the server issues non-expiring tokens it may omit this endpoint; the agent only calls
it when `expires_at` is non-null or after a 401.

---

## 2. Agent lifecycle

```
POST /wpm/v1/agents/register
```
Used when a token already exists but the agent record must be (re)created or its
metadata updated — e.g. after an OS upgrade or an app update.

```json
{
  "name": "Warehouse PC",
  "machine_name": "WH-01",
  "os": "Windows 11 Pro 23H2",
  "app_version": "1.0.0",
  "metadata": { "timezone": "Asia/Kolkata", "locale": "en_IN" }
}
→ 200 { "id": "ag_71ab…", "name": "Warehouse PC", "status": "active", "store_name": "Example Store" }
```

```
GET /wpm/v1/agents/me
→ 200 {
  "id": "ag_71ab…",
  "name": "Warehouse PC",
  "status": "active",              // active | disabled | revoked
  "store_name": "Example Store",
  "store_url": "https://store.example",
  "server_time": "2026-08-15T09:00:00Z",
  "settings": { "poll_interval_seconds": 3, "max_claim_batch": 5 }
}
```

`settings` lets the server suggest values; local Settings always win if the operator has
explicitly changed them.

```
POST /wpm/v1/agents/heartbeat
```
```json
{
  "status": "online",                    // online | paused | error
  "app_version": "1.0.0",
  "queue": { "pending": 3, "printing": 1, "completed": 47, "failed": 0 },
  "printers": [
    {
      "printer_key": "Office Printer",       // stable local identifier
      "name": "Office Printer",
      "driver": "Generic PCL6",
      "port": "USB001",
      "is_default": true,
      "status": "ready",                     // ready|busy|paused|offline|error|out_of_paper|unknown
      "capabilities": ["pdf", "image", "text"],
      "paper_sizes": ["A4", "Letter", "4x6"]
    }
  ],
  "metadata": {}
}
→ 200 { "server_time": "…", "commands": [ { "type": "sync_now" } ] }
```

`commands` is an optional server→agent push channel usable without WebSockets. The agent
understands `sync_now`, `pause`, `resume`, `refresh_printers`, `test_print`
(with `printer_key`), and ignores unknown types.

Sending the printer inventory on heartbeat is what allows wp-admin to offer a real
printer dropdown when configuring which document goes where.

---

## 3. Print jobs

```
GET /wpm/v1/print-jobs?status=queued&limit=10
→ 200 {
  "jobs": [
    {
      "id": 10482,
      "order_id": 5591,
      "document": {
        "type": "pdf",                       // pdf | png | jpeg | html | text | raw
        "url": "https://store.example/wp-json/wpm/v1/print-jobs/10482/document",
        "inline": null,                      // base64 alternative to url
        "filename": "invoice-5591.pdf",
        "sha256": "9f86d081…",
        "size_bytes": 84213,
        "expires_at": "2026-08-15T11:00:00Z"
      },
      "printer": {
        "printer_key": "Thermal Printer",    // may be null → use profile/default
        "allow_fallback": false
      },
      "profile": {
        "name": "4x6 Shipping Label",
        "paper_size": "4x6",
        "width_mm": 101.6,
        "height_mm": 152.4,
        "orientation": "portrait",           // portrait | landscape
        "scaling": "fit",                    // none | fit | fill | actual
        "margins_mm": { "top": 0, "right": 0, "bottom": 0, "left": 0 },
        "copies": 1,
        "quality": "normal",                 // draft | normal | high
        "color": false,
        "duplex": "simplex",                 // simplex | long_edge | short_edge
        "strategy": "auto"                   // auto | spooler | raw | pdf | image | escpos
      },
      "priority": 0,
      "created_at": "2026-08-15T09:00:00Z",
      "metadata": { "document_kind": "shipping_label" }
    }
  ],
  "server_time": "2026-08-15T09:00:01Z"
}
```

Every field under `printer` and `profile` is optional; the agent falls back to local
print profiles and then to the local default printer, subject to §18 of the spec
(no silent substitution unless `allow_fallback` is true).

### Claim

```
POST /wpm/v1/print-jobs/{id}/claim
{ "agent_id": "ag_71ab…" }
→ 200 { "id": 10482, "claimed_until": "2026-08-15T09:05:00Z", … full job object … }
→ 409 if another agent already claimed it
```

Claiming is what makes multi-agent installations safe. The server must claim
atomically (row lock / conditional update), and should expire stale claims so a dead
agent does not strand a job.

### Start

```
POST /wpm/v1/print-jobs/{id}/start
{ "agent_id": "ag_71ab…", "printer_key": "Thermal Printer", "attempt": 1 }
→ 200 { "ok": true }
```

### Complete

```
POST /wpm/v1/print-jobs/{id}/complete
{
  "agent_id": "ag_71ab…",
  "printer_key": "Thermal Printer",
  "attempt": 1,
  "spooler_job_id": 42,
  "completed_at": "2026-08-15T09:00:07Z",
  "duration_ms": 5120
}
→ 200 { "ok": true, "status": "completed" }
```

### Fail

```
POST /wpm/v1/print-jobs/{id}/fail
{
  "agent_id": "ag_71ab…",
  "attempt": 2,
  "error_code": "printer_offline",
  "error_message": "Printer is offline",
  "will_retry": true,
  "next_attempt_at": "2026-08-15T09:00:37Z"
}
→ 200 { "ok": true, "status": "failed" }
```

`error_code` is a stable machine string; the recommended set is
`network`, `document_download`, `document_invalid`, `printer_not_found`,
`printer_offline`, `printer_error`, `spooler_error`, `unsupported_document`,
`cancelled`, `unknown`.

### Cancel / release

```
POST /wpm/v1/print-jobs/{id}/release
{ "agent_id": "ag_71ab…", "reason": "agent_shutdown" }
```
Returns a claimed job to the pool so another agent can take it.

### Document download

```
GET /wpm/v1/print-jobs/{id}/document
Authorization: Bearer <token>
→ 200 binary, Content-Type: application/pdf | image/png | image/jpeg | text/html | text/plain | application/octet-stream
```

The agent will refuse a document whose host is not the paired store origin, whose
content-type contradicts the declared `document.type`, whose magic bytes contradict the
content-type, whose size exceeds the configured cap (default 50 MB), or whose SHA-256
does not match when supplied.

---

## 4. Printers (agent → server)

```
POST /wpm/v1/agents/printers
{ "printers": [ … same shape as in heartbeat … ] }
→ 200 { "ok": true }
```

Used on discovery changes so the admin UI stays current between heartbeats.

---

## 5. Test print (optional)

```
POST /wpm/v1/print-jobs/test
{ "printer_key": "Thermal Printer" }
→ 201 { … job object … }
```

If unavailable, the agent generates a local test page instead; the Test Print feature
never requires server support.

---

## 6. Idempotency

Every state-changing job call carries:

```
Idempotency-Key: <agent_id>:<job_id>:<action>:<attempt>
```

The server should store the key with the response for at least 24 hours and return the
original response for a repeat. This makes "print succeeded but the completion report
timed out" safe: the agent retries the report, the server does not double-count, and the
document is never printed twice.

---

## 7. Minimal server checklist

- [ ] `wp-json/wpm/v1/` namespace registered
- [ ] Pairing start/poll/approve with capability check and rate limiting
- [ ] Bearer token auth (application-password-style hashed storage, not plaintext)
- [ ] `agents/me`, `agents/heartbeat`, `agents/register`, `agents/printers`
- [ ] `print-jobs` listing filtered to the calling agent's store and permissions
- [ ] Atomic `claim` with claim expiry
- [ ] `start` / `complete` / `fail` / `release`
- [ ] Signed or authenticated `document` endpoint with expiry
- [ ] Idempotency-Key storage
- [ ] `Retry-After` on 429
