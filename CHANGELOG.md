# Changelog

## Unreleased — October 2026 improvement plan

Pool acquisition borrows an available authenticated connection before reserving
an empty earlier slot. Connection establishment stays outside the mutex with the
original absolute deadline and joined cancellation/slot-recovery ownership.
Public loopback regressions cover ready/busy/empty/failed/canceled/concurrent
slots without Docker; the supplied starvation reproducer fails on 0.3.0.

## 0.3.0 — October 25, 2026

PG4A adds DNS, absolute connection/authentication/pool-acquisition deadlines and
SCRAM iteration admission (default100000, configurable up to1000000). Results of
joined asynchronous work remain owned until cleanup completes. Cancellation keeps
the selected remote address. Compatibility connection/acquisition APIs remain
available. Backend note saves now include pool acquisition in their15second budget.
PG4B adds optional verified OpenSSL3 memory-BIO TLS, CA/DNS/IP validation,
no plaintext fallback, encrypted cancellation and joined transport deadlines.
TLS-disabled builds fail configured TLS before network use. PG5 adds separate
streamQuery/streamParams iterators with expiring text/null views, explicit owned
copies, connection exclusivity and nonblocking early invalidation. The selected
backend CSV page uses bounded unlinked scratch and row arenas, releasing SQL
before output backpressure; bound admission/page SQL
preserves authorization and saved observations. Offline CI, initially empty-cache archive consumers and affected backend
acceptance gates bind this local feature release. See the development receipt
for exact commits, source/archive hashes, measured budgets and acceptance limits.

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

The improvement candidate adds `getChecked`/`getTyped(T,index)` on owned and
streamed rows with shared conversion, explicit bounds/null/bool/range errors and
generation-first borrowed access. Legacy permissive getters are deprecated for
0.4, retained unchanged in 0.3. Checked floats admit PostgreSQL nonfinite values;
finite-only binding is a separate helper. Examples use typed checked getters.

`test-live` now owns digest-pinned PostgreSQL 16, a dynamic loopback port, marked
container/volume/database/certificates and separate phase/run/cleanup deadlines.
It reuses generic cases without app schemas or sibling repositories, reports
identities and driver heap separately from RSS, and retains the legacy consumer
verifier. Seven control cases cover startup/command/case/outer failures, INT/TERM
and failed cleanup with exact-marker recovery. Offline CI compiles every owner
profile/TLS combination without running Docker; an opt-in CI job runs live gates.

`Pool.healthCheckOpts` accepts one required absolute deadline across acquisition
and SELECT1, preserving separate bounded recovery. Exhaustion, stalled queries,
canceled waits/queries and no-budget-renewal regressions pass in Debug/Safe.
The existing unbounded boolean wrapper retains compatibility.
