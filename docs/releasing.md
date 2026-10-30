# Publishing a release

Use the compiler pinned in `.zigversion` and work from a clean checkout of the
revision being released. Keep unreleased changes under `Unreleased` until a new
version is selected. Do not reuse an existing version tag for different content.

1. Update the version in `build.zig.zon`, the README, and the live report identity
   in `examples/live_fixture.zig`. Move the relevant changelog entries into a
   dated release section. Keep ownership or API compatibility changes explicit.
2. Run `zig build ci -j4 --summary all` and `zig build check-package -j4 --summary all`.
   Run all four live settings and `test-live-controls` from the README. Check
   that the reports record successful cleanup.
3. Commit the tested changes. Create a version tag, such as `v0.3.1`, at that
   exact commit, then push the repository and tag to the chosen GitHub remote.
4. Create a GitHub release for the tag. Include the changelog entry, compiler
   version, supported platform/server, and validation results.
5. From a separate consumer, run `zig fetch --save=postgres` with the full GitHub
   commit archive URL. Commit the resulting URL and hash in the consumer's
   `build.zig.zon`; compile that consumer before announcing the release.

For a local reproducible archive of a committed revision:

```sh
git archive --format=tar --prefix=postgres/ HEAD | gzip -n > postgres-package.tar.gz
zig fetch file:/absolute/path/postgres-package.tar.gz
```

The package checker also creates an archive from the current package paths so
that uncommitted release-preparation changes can be checked before committing.
Both archives must include the project’s MIT license and the dependency pin in `build.zig.zon`.

Repository setup and publication are separate from local preparation. Choose the
GitHub owner, add its remote, and publish only the revision you intend to share.
