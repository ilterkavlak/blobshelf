# AGENTS.md

Instructions for AI coding agents (and humans) working in this repository. Read this file before
changing anything.

## The one rule that overrides everything

**This app must be safe to run.** People install it on their own Mac and point it at their files.
A change that makes the app weaker in any way is wrong, however convenient. When in doubt, stop and
ask the maintainer instead of guessing.

Never:

- Add an entitlement to `Support/Blobshelf.entitlements` or a hardened-runtime exception. The
  four entitlements there are the whole permission set.
- Send data to any host other than `blob.upstash.io` (token exchange) and
  `*.r2.cloudflarestorage.com` (storage). No analytics, crash reporters, update checks or
  third-party APIs.
- Create a `URLSession` of your own. All traffic goes through `HTTP.session`
  (`Sources/BlobshelfCore/Net/HTTP.swift`): no disk cache, no cookies, no redirects.
- Write a token, credential or signature anywhere but the Keychain or memory: not in config,
  `UserDefaults`, logs, error messages, files or test fixtures.
- Add logging of file names, keys, paths or request details.
- Let backups delete or modify local files, or delete remote objects. Backup folders are opened
  through read-only security-scoped bookmarks.
- Allow backups into public buckets, or open bucket files that could run code (see
  `FileIcon.isSafeToOpen`).
- Weaken path handling for downloads (`LocalPathAllocator` keeps every path inside the folder the
  user chose).
- Add a third-party dependency, `curl | sh`, or `sudo` anywhere, including scripts.

Security-relevant changes need a test that would fail without them, and an update to the
Permissions and "What leaves your Mac" sections of `README.md`.

## Where things are

| Path | What it is |
|---|---|
| `Sources/BlobshelfCore/Net/` | `HTTP` (the only URLSession), bounded concurrency helper, progress throttling |
| `Sources/BlobshelfCore/Blob/` | Token decoding, the credentials API, the credential cache |
| `Sources/BlobshelfCore/S3/` | SigV4 signing, key encoding, XML parsing, the S3 client (multipart, retries) |
| `Sources/BlobshelfCore/Drive/` | Folder semantics over keys, download path allocation |
| `Sources/BlobshelfCore/Backup/` | Backup jobs, scanner, excludes, planner, manifest, engine, FSEvents watcher |
| `Sources/BlobshelfCore/Store/` | Keychain and JSON config storage, app paths |
| `Sources/Blobshelf/` | SwiftUI app: `AppModel` (state, transfers, backup scheduling), views, menu bar panel |
| `Tests/BlobshelfCoreTests/` | Swift Testing suites; `Live*` suites run against a real bucket |
| `Support/Blobshelf.entitlements` | The app's entire permission set |
| `scripts/` | `test.sh`, `build-app.sh` (bundle + ad-hoc signing), `make-icon.swift` |
| `install.sh` | What end users run to build and install |
| `uninstall.sh` | Removes the app, its data and its Keychain tokens; keep it in sync with what the app stores |

Logic belongs in `BlobshelfCore`, which has no UI and is fully testable. The app target stays a
thin layer of state and views.

## Build, test, run

Only Apple's Command Line Tools are required (Swift 6, macOS 14+). Xcode works too.

```bash
swift build                 # must finish with zero warnings
scripts/test.sh             # unit tests (use this, not plain `swift test`, without Xcode)
scripts/build-app.sh        # build/Blobshelf.app, sandboxed and ad-hoc signed
codesign -d --entitlements - "build/Blobshelf.app"   # must list exactly the 4 entitlements
```

Live tests: `UPSTASH_DISK_TEST_TOKEN=<read-write token of a throwaway bucket> scripts/test.sh`.
They work under a random prefix and delete it afterwards. Never commit a token.

Tests that use `StubProtocol` share a global handler, so they must be in (or extend) the
serialized `S3ClientTests` suite.

## How to work here

- Keep diffs as small as the change allows. No drive-by refactors, no speculative abstractions.
- No duplicated logic: reuse the existing helper (`concurrentForEach`, `HTTP.session`,
  `BackupStatusLine`, `FileIcon`, …) or extract one when a second copy would appear.
- No dead code, unused parameters or `public` API nothing uses.
- Comments explain a non-obvious *why*, never restate the code.
- Swift 6 strict concurrency: no `@unchecked Sendable` or `nonisolated(unsafe)` without a lock
  and a reason.
- Every behavior change comes with a test. Run the full suite before you finish.
- Keep `README.md`, `SECURITY.md` and this file in sync with the code.

## Before you finish

1. `swift build` has no warnings, `scripts/test.sh` passes.
2. `scripts/build-app.sh` succeeds and the entitlements are unchanged.
3. `git diff` contains only what the task needs: no debug output, no stray files, no secrets.
4. If you touched networking, storage of anything, file access or backups, re-read
   "The one rule" above against your diff.
