# AGENTS.md — working on the official Spider modules

The modules here (`notify/`, `pdf/`) are packages of their own, built and
tested against Spider. How to write one: `CONTRIBUTING.md`. The check that
Spider's CI runs on every change: `scripts/ecosystem.sh` (unit tests of
every module, then each module's database tests on a disposable Postgres).

## Rules

- **Everything in this repository is 100% English**: code, comments, test
  data, messages, documentation and commit messages.
- **Only Spider and its modules in this repository.** Code, comments,
  tests, test data, docs, examples and commit messages describe the
  modules on their own terms: no other frameworks, libraries or tools as
  comparisons or examples ("like X does"), no applications or companies
  that use them, no benchmarks against other projects, no ids from outside
  issue trackers. What a module integrates (Web Push, FCM, email
  providers, Postgres, ...), standards and Zig are fine, and so are credits
  the maintainer asked for. Anything else only when the maintainer asks for
  it explicitly, in that conversation. Before every commit, read the diff
  and the message for it.
- A new Spider minor needs each module's `.spider` range moved, after its
  tests pass against that Spider (`SPIDER_DIR=<spider> scripts/ecosystem.sh`).
