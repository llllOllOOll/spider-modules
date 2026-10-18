# Writing a Spider module

The same rules apply to an official module here and to a third-party module
in its own repository. Spider checks the contract; these rules keep the
modules consistent and reviewable.

## The package

- One directory per module, a package of its own: `build.zig`,
  `build.zig.zon` (a real `fingerprint`: let `zig build` generate it),
  `src/`, `test/`, `scripts/test-db.sh` when it has tables.
- **No dependency on Spider in `build.zig.zon`.** The app passes its own
  `spider` module in (`.imports = &.{.{ .name = "spider", .module = spider_mod }}`),
  so there is one Spider in the build. This repository's root `build.zig`
  does the same for the tests.
- The package name is `spider_<name>`; the module name in the manifest is
  `<name>`.
- 100% English: code, comments, messages, documentation, commits.

## The manifest

```zig
pub const spider_module = spider.module(.{
    .name = "notify",
    .version = "0.2.0",
    .spider = ">=0.11.0-dev.1 <0.12.0",
    .requires = .{}, // other modules, by name
    .migrations = .{
        .{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") },
    },
    .env = .{ .required = .{}, .optional = .{} },
});
```

- `version` is the module's semver. Breaking changes bump the major (or the
  minor before 1.0) and go to the changelog.
- `spider` is the range the ecosystem check **passed** on; do not widen it
  by hand.
- Every environment variable the module reads is listed in `env`.

## Migrations

- In `src/sql/`, named `NNNN_description.sql`, listed in the manifest in the
  order they run.
- PostgreSQL, forward only. No `BEGIN`/`COMMIT`: Spider runs each one in a
  transaction of its own, with its `schema_migrations` row.
- **Never edit a released migration.** Spider records a checksum and refuses
  to start (and to migrate) when an applied migration changed. Add a new one.
- Prefer `CREATE ... IF NOT EXISTS` in a first migration that may meet a
  database where an app created the same tables by hand before.

## Lifecycle

| Declaration | Signature | When |
|---|---|---|
| `check` | `pub fn check(c: *spider.Check) !void` | before any module boots; `c.fail(...)` for each problem; no side effects |
| `boot` | `pub fn boot(b: spider.Boot) !void` | in dependency order, before the app's features |
| `shutdown` | `pub fn shutdown(b: spider.Boot) void` | from `server.deinit()`, in reverse order, after the jobs stopped |
| `jobs` | `pub const jobs = .{spider.every(ms, fn)}` | started by `listen()` |
| `routes` | a struct of `pub fn name() spider.Group` | mounted by `mountModules` |

Spider already checks the declared environment variables and that the
migrations are applied and unchanged; `check` covers what only the module
knows (it can read its tables, an extension is installed, two settings
agree).

## Tests

- Unit tests next to the code (`zig build test-<name>`).
- With tables: a module test that goes through Spider (`checkModules` not
  ready → `migrateModules` → ready), then the database tests on the tables
  Spider created, on a disposable Postgres (`scripts/test-db.sh`, tmpfs, a
  port of its own). Never against a database you care about.
- `scripts/ecosystem.sh` must pass before a change is merged.

## Third-party modules

Publish the package anywhere; apps fetch it by URL and hash. To be tested
against Spider releases, add your repository to the ecosystem list in the
Spider docs: your failures are reported to you and never block a Spider
release.
