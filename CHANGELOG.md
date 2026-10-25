# Changelog

## Unreleased

PG4A adds DNS, absolute connection/authentication/pool-acquisition deadlines and
SCRAM iteration admission (default100000, configurable up to1000000). Results of
joined asynchronous work remain owned until cleanup completes. Cancellation keeps
the selected remote address. Compatibility connection/acquisition APIs remain
available. Backend note saves now include pool acquisition in their15second budget.
TLS/streaming and feature-release gates remain pending.

## 0.2.0 — October 24, 2026

Feature release accepting PG0–PG3: transaction state and safe pool reuse, joined
500ms rollback/error cleanup, validated bounded text-query decoding and private
SQLSTATE diagnostics, bound parameters and separately configurable operation/
commit deadlines. Existing owned results and simple-query APIs remain available.
Contact-note create/edit adopt parameters in the backend; domain SQL and policy
remain outside this package. No schema change is required.

`queryParams`/`queryParamsOpts` admit one statement and tuple values; unsupported
values fail before I/O. Defaults add1024parameters/32MiB complete requests and
finite SQL/message/cell/result/row/column limits. See README for exact defaults,
ownership and deadline semantics. Default build/tests stay offline; live fixtures
require an explicitly owned disposable database.

Verified with Zig0.17.0 in Debug/ReleaseSafe and PostgreSQL16.13. DNS, TLS, general
connect/pool/authentication bounds, streaming, metadata APIs and other server
versions retain separate acceptance gates. No automatic write replay or external
publication is included.

Rollback requires reverting note create/edit's parameter/deadline adoption along
with the package pin when returning to0.1.0; the older API lacks those additions.
Database schema/data need no downgrade. Preserve unknown commit outcomes and
application authorization/audit boundaries during any consumer rollback.

## 0.1.0

Independent local extraction of the backend's PostgreSQL wire-v3 runtime,
compatibility adapters and standalone offline public consumer.
