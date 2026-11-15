# Security policy

Blobshelf handles bucket tokens and copies of your files, so security reports are taken
seriously and handled first.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository instead.
Include what you found, how to reproduce it, and what an attacker could do with it.

You can expect an acknowledgement within a few days. Fixes are released as soon as they are
ready, and reporters are credited unless they prefer not to be.

## Supported versions

Only the latest commit on `main` is supported. Users build from source, so updating is
`git pull && ./install.sh`.

## Security model

What the app is designed to guarantee:

- It runs in the macOS App Sandbox with the hardened runtime and exactly four entitlements:
  App Sandbox, outgoing network connections, files the user picks, and remembering picked folders.
- Backup folders are opened read-only. Backups never modify or delete files on the Mac and never
  delete objects in a bucket.
- Bucket tokens live only in the macOS Keychain. Storage credentials live only in memory and
  expire after about ten minutes.
- Tokens are only ever sent to `https://blob.upstash.io`. Storage credentials are only ever used
  against `https://*.r2.cloudflarestorage.com`. Redirects are refused, and nothing is cached on disk.
- Backups refuse public buckets, and skip common secret files (SSH and GPG keys, `.env`, cloud
  credentials, shell history) unless the user removes those exclude patterns.
- Files from a bucket that could run code (apps, scripts, installers, disk images, unknown types)
  are never opened, only previewed. Every file the app writes carries the macOS quarantine flag.
- Opened files are read-only copies, cached only while the app runs and deleted at launch, at
  quit, and when their bucket is removed.

What it does **not** protect against (non-goals):

- **Your storage provider.** Files are encrypted in transit (HTTPS) and at rest by the provider,
  but not end-to-end. Upstash and Cloudflare, as operators of the storage, could technically
  read them.
- **Anyone holding a bucket token.** A token grants access to its whole bucket. Treat it like a
  password and rotate it if it leaks.
- **A compromised Mac or user account.** Malware running as you can read what you can read.
- **Malicious code in a fork.** You build what you clone. Only build from a source you trust,
  and read the diff before updating.

## Scope

In scope: the code in this repository, its build and install scripts, and the app they produce.
Out of scope: Upstash's and Cloudflare's services themselves (report those to the vendor), and
issues that require an attacker who already controls your Mac.
