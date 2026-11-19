# Changelog

## Unreleased

- Prefer an available authenticated pool connection before opening a new one.
- Add checked text and typed scalar getters for owned and borrowed rows.
  Legacy permissive getters remain available and are deprecated for removal or
  signature changes in a breaking 0.4 release.
- Add an independent Docker-based PostgreSQL 16 acceptance suite, with bounded
  startup, execution, cancellation, and owned cleanup.
- Update the standalone verification suite to `zig-process` 0.6.1.
- Add `Pool.healthCheckOpts` with one absolute acquisition/query deadline.
- Add owned PostgreSQL URI configuration, finite floating-point parameter
  binding, final command counts, and optional single-row helpers.
- Add synchronized pool capacity, availability, waiter, and connection-lifetime
  statistics.
- Add MIT licensing, public installation and API documentation, automatic
  GitHub-hosted CI, and an archive-consumer packaging check.

## 0.3.0 — 2026-10-25

- Add DNS, IPv4/IPv6 connection options, absolute connection/authentication and
  pool-acquisition deadlines, and bounded SCRAM iteration admission.
- Retain the selected remote endpoint for cancellation requests.
- Add optional verified OpenSSL 3 TLS, CA and DNS/IP identity validation,
  encrypted cancellation, and joined transport deadlines. TLS failures never
  fall back to plaintext.
- Add separate streaming query and parameter iterators, expiring borrowed rows,
  explicit owned copies, and safe abandoned-stream invalidation.
- Add offline Debug/Safe and plaintext/TLS build checks and public consumers.

## 0.2.0 — 2026-10-24

- Add transaction-aware pool release and bounded rollback/error cleanup.
- Validate bounded text-query decoding and retain owned SQLSTATE diagnostics.
- Add single-statement bound parameters and configurable query/commit deadlines.
- Bound SQL, messages, cells, rows, columns, retained results, parameter counts,
  and complete encoded requests.
- Keep owned text/null results and simple-query APIs available.

## 0.1.0

- Extract the PostgreSQL wire-v3 runtime into an independent package with a
  standalone public consumer and offline tests.
