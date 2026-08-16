# Security model

A print agent is, structurally, a program that authenticates to a remote server,
downloads files it did not create, and feeds them to a device driver, on an
unattended computer, indefinitely. This document states what that program is and
is not allowed to do, and where in the code each rule is enforced.

---

## 1. Absolute rules

| Rule | Enforced in |
|---|---|
| Never ask for, transmit or store a WordPress username or password. | Pairing is the only credential flow — `AgentSession.pair`, `PrintAgentApi.startPairing`. There is no password field anywhere in the UI. |
| Never disable TLS certificate validation. | There is no `badCertificateCallback` in the codebase. A handshake failure becomes `TlsValidationException` and is **not** retried. |
| Never store a secret in source. | No API key, no salt that is a secret, no default credentials. The DPAPI entropy in `secure_credential_store.dart` is an application scoping value, documented as non-secret. |
| Never log a token. | `Redaction` runs inside `AppLogger.log`, before any sink. `AgentCredentials.toString()` returns a redacted string. |
| Never execute a downloaded file. | Downloads are written with an agent-generated filename and only ever read by the print pipeline. The one external process the agent launches is a fixed argument list against a known browser binary. |
| Never download from an unapproved origin. | `UrlValidator.assertAllowedDocumentUrl` runs before the request is issued. |
| Never print the same server job twice. | Four layers — see §6. |

---

## 2. Credentials

**Never stored:** WordPress passwords, application passwords typed by a user,
cookies.

**Stored:** one bearer token per paired agent, plus an optional refresh token.

Storage is `%APPDATA%\WooCommercePrintAgent\credentials\<agentId>.bin`,
encrypted with the Windows Data Protection API (`CryptProtectData`) in **user
scope**, with an application entropy value mixed into the key derivation.

Consequences, all intended:

* Copying the file to another machine yields nothing.
* Reading it as a different Windows user yields nothing.
* Another program running as the same user cannot decrypt it without also
  knowing the application entropy.
* If Windows cannot decrypt it — a restored profile, a different account — the
  agent treats the credentials as absent and requires re-pairing. It never falls
  back to anything weaker.

The plaintext token exists only in memory, only inside `AgentSession`, and is
written to exactly one place: the `Authorization` header.

On a non-Windows host `UnencryptedFileCredentialStore` is selected. It reports
`isEncrypted == false`, warns on every use, and Diagnostics shows it as a
warning. It exists so the app runs on a developer's machine; it is never
selected on Windows.

---

## 3. Pairing

```
Agent                          Store (wp-admin)
  │  POST /pairing/start            │
  ├────────────────────────────────►│  creates a short-lived request
  │  ◄── pairing_id + code          │
  │                                 │
  │  operator reads the code        │  administrator, already signed in,
  │  to an administrator            │  approves the matching request
  │                                 │
  │  GET /pairing/{id}  (polled)    │
  ├────────────────────────────────►│
  │  ◄── credentials (once)         │
```

Properties the server must uphold, documented in `API_INTEGRATION.md`:

* `pairing/start` and the polling endpoint are rate-limited per IP.
* Approval requires an authenticated administrator with a capability check.
* Codes are single-use and short-lived (≤ 10 minutes recommended).
* Credentials are returned exactly once.
* Tokens are stored hashed server-side, like WordPress application passwords.

The agent's side: the code is displayed but never logged (the redaction filter
masks the `XXX-XXX-XXX` shape), polling stops on any terminal status, and the
temporary unauthenticated client used for the handshake is closed afterwards.

---

## 4. Transport

* HTTPS only. `UrlValidator` rejects `http://` for any non-loopback host, at
  pairing time and again per document.
* Certificate validation is on. `DioExceptionType.badCertificate` and
  `HandshakeException` map to `TlsValidationException`, which is
  **non-retryable** — a broken certificate is a configuration problem to be
  fixed, not a transient error to be papered over by retrying.
* Every request carries `X-Request-Id`; state-changing job calls carry
  `Idempotency-Key`.
* Request and response *bodies* are never logged. Only method, path (with the
  query string sanitised), status, duration and request id are.

---

## 5. Documents

Before a single byte reaches a printer, a payload has passed:

| Check | Rejects |
|---|---|
| Origin | Anything not on the paired store's exact origin (scheme + host + port) or an explicitly approved additional origin. A subdomain is not the same origin. |
| Scheme | Anything that is not HTTPS. |
| Size | Anything over the configured cap (default 50 MB). Non-retryable. |
| Completeness | A body shorter or longer than the declared `size_bytes`. |
| Content type | A `Content-Type` that contradicts the declared document type. An HTML body where a PDF was promised is called out specifically, because that is what an expired document link looks like. |
| Magic bytes | Content whose signature contradicts the declared type. |
| Checksum | A SHA-256 mismatch when the server supplied one. |
| Expiry | A document past its `expires_at`. |

The filename written to disk is derived from the agent's own job id, never from
the server-supplied name — a `..\..\Windows\System32\evil.exe` filename cannot
escape the documents folder. The server's name is used only as the spooler's
document title, and `PrintDocument.safeFilename` strips path separators from it
regardless.

Downloaded files are deleted after a successful print, and the whole documents
folder is swept of anything older than 24 hours on the maintenance pass.

### The one external process

`HtmlPrintStrategy` shells out to headless Microsoft Edge to convert HTML to
PDF. This is the only process the agent ever launches. It is constrained:

* The executable is looked up at fixed, known install paths — never taken from
  the document, the server, or `PATH`.
* The argument list is fixed; the only variable parts are the agent's own
  temporary file path and page dimensions.
* The input is a `file://` URL to a file the agent itself wrote.
* The run is bounded by a timeout, and both temporary files are deleted after.
* If Edge is absent, the strategy degrades to printing stripped text and says so
  in the log and in Diagnostics. It never fails open to something riskier.

---

## 6. Duplicate protection

Printing a shipping label twice costs money; printing an invoice twice confuses
a customer. Four independent guards, any one of which is sufficient:

1. **Database.** `UNIQUE (store_id, server_job_id)` on `print_jobs`, with
   `INSERT OR IGNORE`. A re-offered job cannot create a second row.
2. **State.** `PrintJobDao.markPrinting` re-reads the row inside a transaction
   and refuses if it is already terminal.
3. **Lease.** The transition to `printing` records a per-process lease owner. A
   different owner cannot complete or reprint it, and a foreign owner found at
   startup proves the previous process died mid-print.
4. **Idempotency.** Every state-changing call carries
   `<agent>:<job>:<action>:<attempt>`, recorded locally *before* the call and
   confirmed after. A crash between "printed" and "reported" replays the
   *report*, never the print.

### Crash recovery

A job found in `printing` at startup is moved to `interrupted`, not requeued.
The agent cannot know whether the paper came out, so it asks. The operator gets
**Mark as printed** / **Print again** on the queue screen. Sites that prefer an
unattended default can change **Settings → After an unexpected shutdown**, and
the choice is explicit and logged.

---

## 7. Local footprint

```
%APPDATA%\WooCommercePrintAgent\
├── agent.db        no tokens, no passwords
├── credentials\    DPAPI-encrypted, user-scoped
├── logs\           redacted, size-capped, rotated
└── documents\      transient, swept after 24 h
```

The agent writes nowhere else. It touches exactly one registry value —
`HKCU\...\Run` — and never `HKEY_LOCAL_MACHINE`. It requires no administrator
rights at install or at runtime.

---

## 8. Log safety

`Redaction` masks, before any sink sees a record:

* `Bearer <token>` in free text
* `token` / `access_token` / `refresh_token` / `api_key` / `secret` / `password`
  / `pairing_code` in `key: value` or `key=value` form
* plugin-issued `wpm_at_…` / `wpm_rt_…` tokens anywhere in a string
* pairing codes matching `XXX-XXX-XXX`
* any context map key in the sensitive-keys set, recursively
* URL user-info and sensitive query parameters

The exported support bundle is the same redacted content plus a header, which is
why "Export logs" is safe to hand to a customer without review.

---

## 9. Reporting a vulnerability

Do not open a public issue. Contact the maintainer listed in `installer/print_agent.iss`
(`AppPublisher` / `AppURL`) — replace those placeholders with your own security
contact before distributing a build.
