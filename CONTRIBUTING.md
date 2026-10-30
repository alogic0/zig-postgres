# Contributing

Use the exact Zig version in [`.zigversion`](.zigversion). The supported test
platform is Linux x86_64. Keep changes focused and describe the behavior and
validation in the pull request.

Before submitting, run:

```sh
zig fmt build.zig build.zig.zon src examples tests/package tools
zig build ci -j4 --summary all
zig build check-package -j4 --summary all
```

The offline CI command exercises Debug/Safe and plaintext/TLS builds without
Docker or PostgreSQL. The package check builds a separate consumer from a source
archive with fresh caches using a Zig helper and the same compiler.

For connection, protocol, transaction, streaming, or TLS changes, also run the
applicable standalone live cases described in the [README](README.md). Run
`zig build test-live-controls -j4` when changing fixture lifecycle or cleanup.
Include the commands and outcomes in your pull request; generated JSON reports
belong in build outputs, rather than source control.

Preserve allocator and row ownership, cancellation joining, absolute deadlines,
transaction-aware pool release, and ambiguous COMMIT outcomes. Avoid logging
credentials, query parameters, or raw server errors. New APIs should document
their ownership and error behavior in [docs/api.md](docs/api.md), with user-facing
changes recorded in [CHANGELOG.md](CHANGELOG.md).
