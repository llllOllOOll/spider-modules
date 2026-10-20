# spider-modules

The official modules of [Spider](https://github.com/llllOllOOll/spider):
packages that plug into a Spider app through the module contract
(Spider RFC 0001). Each module:

- declares a manifest (`pub const spider_module = spider.module(.{ ... })`)
  that Spider checks at compile time: its name, version, the Spider versions
  it is tested with, the modules it requires, its migrations and the
  environment variables it reads;
- ships its own database migrations, which `spider migrate` applies and
  records as `module/name` with a checksum;
- may expose `check` (run before the server starts: a failure keeps it from
  listening), `boot`, `shutdown`, `jobs` and `routes`.

| Module | What it does | Spider |
|---|---|---|
| [`notify`](notify/) | Multi-channel notifications: transactional outbox, inbox, SSE, Web Push, FCM, email, retries and deduplication | `>=0.11.0-dev.1 <0.12.0` |
| [`pdf`](pdf/) | PDF documents: write (fonts with subsetting and kerning, tables, paths, gradients, images, forms, bookmarks) and edit existing ones (merge, split, stamp, fill forms, encrypted files); std only | `>=0.11.0 <0.12.0` |

## Using a module

```zig
// build.zig — the module gets the app's own spider
const modules_dep = b.dependency("spider_modules", .{});
const notify_mod = b.createModule(.{
    .root_source_file = modules_dep.path("notify/src/notify.zig"),
    .target = target,
    .imports = &.{.{ .name = "spider", .module = spider_mod }},
});
exe.root_module.addImport("spider_notify", notify_mod);

// main.zig — modules first, then the app's features
_ = server.mountModules(.{@import("spider_notify")}).mountFeatures(features);
```

Then `spider migrate` (the modules' migrations run before the app's) and
`spider check --modules` (or just start the app: it refuses to listen while
a module is not ready, and says why).

`pdf` is wired the same way (`pdf/src/pdf.zig`, imported as `spider_pdf`);
it has no migrations, and mounting it is optional.

Add the repository to `build.zig.zon` pinned to a commit, which `zig
fetch` writes with its hash:

```sh
zig fetch --save=spider_modules "git+https://github.com/llllOllOOll/spider-modules#<commit>"
```

While working on a module, `zig build --fork=../spider-modules` in the app
builds it from a local checkout instead, without touching `build.zig.zon`.

## Compatibility

Every module states the Spider range it was **tested** with. The
[ecosystem check](scripts/ecosystem.sh) builds and tests every module
against a Spider checkout:

- Spider's release gate runs it against each release candidate: a Spider
  release does not ship while an official module fails;
- it runs nightly against Spider `main`;
- when it passes on a new Spider version, the modules' ranges are extended
  to include it.

## Layout and tests

```
build.zig            wires every module to one Spider for the tests
<module>/            one package per module: build.zig, build.zig.zon,
                     src/ (src/sql/ for migrations), test/, scripts/test-db.sh
scripts/ecosystem.sh every module against one Spider
```

The tests use the Spider pinned in `build.zig.zon`, or a Spider checkout
given with `--fork` (a path relative to this repository):

```sh
zig build test                    # unit tests, against the pinned Spider
zig build test --fork=../spider   # the same, against a checkout
notify/scripts/test-db.sh         # notify on a disposable Postgres (Docker)
pdf/scripts/check.sh              # pdf's sample document through qpdf and pdftotext
scripts/ecosystem.sh              # everything against ../spider (SPIDER_DIR), as the release gate runs it
```

Writing a module: [CONTRIBUTING.md](CONTRIBUTING.md).
