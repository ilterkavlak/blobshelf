<div align="center">

# Blobshelf

**A native Mac app for your Upstash Blob buckets, with automatic folder backups.**

[![CI](https://github.com/ilterkavlak/blobshelf/actions/workflows/ci.yml/badge.svg)](https://github.com/ilterkavlak/blobshelf/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![App Sandbox](https://img.shields.io/badge/App%20Sandbox-on-2ea44f)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

Blobshelf is a small native macOS app for [Upstash Blob](https://upstash.com). Browse your
buckets in the app's own window, with folders, drag and drop and Quick Look, and keep folders on
your Mac backed up to them automatically. It is a standalone app: your buckets don't appear in
Finder as a mounted drive. It runs in Apple's App Sandbox with the smallest set of permissions it
can work with, and you build it yourself from this source.

> [!NOTE]
> This is an independent open-source project, not an official Upstash product. It was
> **vibe coded**: written almost entirely by AI. Read [How this was built](#how-this-was-built)
> before you trust it with data that matters.

## Contents

- [Features](#features)
- [Security at a glance](#security-at-a-glance)
- [Install](#install)
- [Get started](#get-started)
- [Permissions](#permissions)
- [What leaves your Mac](#what-leaves-your-mac)
- [How it works](#how-it-works)
- [Develop](#develop)
- [How this was built](#how-this-was-built)
- [Uninstall](#uninstall)
- [License](#license)

## Features

- **Browse** any number of buckets in a list or grid: folders, upload (button or drag and drop,
  folders included), download, Quick Look, rename, delete, new folder, search, and copyable links
  for public buckets.
- **Back up folders automatically.** Pick a folder and a bucket. New and changed files are
  uploaded a few seconds after they change, on a schedule, and when you click Back Up Now.
  Backups only add and update: deleting a file on your Mac never deletes it from the bucket.
- **Menu bar status.** The icon shows whether everything is backed up, syncing, paused or needs
  attention, and its panel lists every backup and transfer with progress. The app keeps running
  there when you close its window.
- **Fast.** Large files upload in parallel parts, backups upload eight files at a time, and
  only new or changed files are sent.

## Security at a glance

- 🔒 Runs in the **App Sandbox** with the hardened runtime and only **four** permissions.
- 📁 Sees only the files and folders **you pick**. Backup folders are opened **read-only**.
- 🔑 Bucket tokens are stored in your **Keychain**, never in files or logs.
- 🌐 Talks to exactly two services over HTTPS: `blob.upstash.io` and Cloudflare R2. No
  analytics, tracking or update checks. Nothing is cached on disk and redirects are refused.
- 🚫 Refuses to back up into **public** buckets, and skips **secrets** such as SSH keys, `.env`
  files and cloud credentials by default.
- 🛡️ Never runs code from a bucket: apps, scripts and installers are only previewed, and
  everything it downloads is quarantined so macOS checks it first.
- 🧩 No third-party dependencies. You compile every line yourself.

Details are in [Permissions](#permissions) and [SECURITY.md](SECURITY.md).

## Install

You build the app yourself from this repository. It takes about a minute. You need macOS 14
(Sonoma) or newer, on Apple silicon or Intel.

1. Install Apple's Command Line Tools (skip this if you have Xcode):
   ```bash
   xcode-select --install
   ```
2. Download the code:
   ```bash
   git clone https://github.com/ilterkavlak/blobshelf.git
   cd blobshelf
   ```
3. Build and install:
   ```bash
   ./install.sh
   ```

The app is installed in `/Applications` (or `~/Applications` if that is not writable) and opens.
To update later, run `git pull && ./install.sh` in the same folder.

## Get started

1. Click **Add Your First Bucket** and paste the bucket's token from the
   [Upstash console](https://console.upstash.com). Add as many buckets as you like.
2. Choose a bucket in the sidebar to browse it. Drop files onto the window to upload them.
3. Open **Backups → Add Backup** and choose a folder, a private bucket and where in the bucket it
   goes (by default `Backups/<folder>-<id>/`). Exclude patterns are shell globs such as `.git` or
   `*.tmp`, one per line.
4. Optional: **Settings → Open at login**, so backups keep running after a restart.

## Permissions

These are everything the app may do, from
[`Support/Blobshelf.entitlements`](Support/Blobshelf.entitlements):

| Permission | Why |
|---|---|
| App Sandbox | Walls the app off from the rest of your Mac. |
| Outgoing network connections | To reach `blob.upstash.io` and your bucket's storage over HTTPS. Nothing can connect *to* the app. |
| Files you choose (read/write) | Only files and folders you pick in an Open dialog or drag onto the window. Write access is used only to save downloads where you chose. |
| Remember chosen folders | So backups can read their folders after a restart. Backup folders are remembered **read-only**: a backup can never change or delete your files. |

**What macOS may show you:**

- **Keychain**, after you rebuild or update the app: *"Blobshelf wants to use your
  confidential information stored in … in your keychain."* Click **Always Allow**. macOS asks
  again because a self-built app gets a new signature on every build.
- **Login Items**, only if you turn on Open at login: a *"Background Items Added"* notification.
  You can turn it off in System Settings → General → Login Items.
- **"Downloaded from the internet"**, when you first open a downloaded app or script yourself.
  This is the quarantine flag doing its job.

**What the app never asks for:** Full Disk Access, access to your Desktop, Documents or Downloads
as a whole, Accessibility, Screen Recording, Automation (Apple Events), Notifications, Location,
Camera, Microphone, Contacts, Bluetooth, or incoming connections. macOS shows no "unidentified
developer" warning for the app itself, because you built it on this Mac.

## What leaves your Mac

| What | Sent to | Why |
|---|---|---|
| Bucket token | `https://blob.upstash.io` | Exchanged for storage credentials that expire after about 10 minutes. |
| Files you upload, and new or changed files in your backup folders, with their names and folder paths | Your bucket on Cloudflare R2 (`*.r2.cloudflarestorage.com`) | That is the point of the app. |

Nothing else: no usage data, no device or computer name, no file listings beyond what you back
up. Data is encrypted in transit and stored encrypted by the provider, but it is **not**
end-to-end encrypted, so Upstash and Cloudflare, as operators of the storage, could read it. Anyone
with a bucket's token can read and change everything in that bucket.

**Where your data lives on the Mac:** tokens in the login Keychain; storage credentials only in
memory; settings and backup records in the app's container,
`~/Library/Containers/io.github.ilterkavlak.blobshelf`. Files you open from a bucket are
read-only copies kept there only while the app runs; use **Save As** in the other app to keep
changes.

## How it works

```
token ──HTTPS POST /v1/credentials──▶ blob.upstash.io      short-lived S3 credentials for one bucket
app ───HTTPS, S3 SigV4──────────────▶ <account>.r2.cloudflarestorage.com/<bucket>/<key>
public files ───────────────────────▶ https://<bucket hash>.blob.upstash.io/<key>
```

A backup run scans the folder, lists its destination, and uploads every file that is missing
there, has a different size there, or changed on the Mac since its last upload (tracked in a
per-backup record). Folder changes are noticed through FSEvents. The app's own data is never
backed up.

| Path | Contents |
|---|---|
| `Sources/BlobshelfCore` | Everything without a UI: networking, token and credentials, S3 client and signing, drive semantics, backup engine, Keychain and config. |
| `Sources/Blobshelf` | The SwiftUI app and its menu bar panel. |
| `Tests/BlobshelfCoreTests` | Unit tests, plus live tests against a real bucket. |
| `Support`, `scripts`, `install.sh`, `uninstall.sh` | Entitlements, build, packaging and install scripts. |

## Develop

```bash
swift build             # build
scripts/test.sh         # unit tests (works with only the Command Line Tools)
scripts/build-app.sh    # build/Blobshelf.app, sandboxed and signed, without installing
swift run               # run unbundled and unsandboxed, for quick UI iteration
```

Set `UPSTASH_DISK_TEST_TOKEN` to a read-write token of a **throwaway** bucket to also run the
live tests. They upload, rename, download and delete objects under a random prefix and clean up
afterwards.

Contributions are welcome. Read [AGENTS.md](AGENTS.md) first: it describes the layout and the
rules every change must follow, human or AI. Security issues go through [SECURITY.md](SECURITY.md).

## How this was built

Honesty matters here, so: this project was **vibe coded**. Its owner described what they wanted,
and AI wrote the code. Anthropic's Claude (in Claude Code) wrote it, and OpenAI's Codex reviewed
the plans and the code over several rounds until neither found anything left to fix. An
independent AI security audit was also run. No human has reviewed the code line by line.

What has been verified:

- 64 automated tests pass, including live tests against a real Upstash Blob bucket:
  - large multipart uploads, and file names with spaces, symbols, Turkish, Japanese and emoji;
  - more than 1,000 objects, renames and deletes;
  - credential refresh after a rejected key;
  - incremental backups that skip secrets and never delete.
- CI builds the app, runs the tests, and checks that the entitlements are exactly the four
  listed above.
- The packaged app launches sandboxed with those entitlements.

What has **not** been verified:

- No human security audit.
- No UI tests. The interface has not been covered by a test suite or a scripted walkthrough.

Please read the code before trusting it with data that matters. It is small: about 3,000 lines
of Swift with no dependencies. Keep your own copies of anything important, and report problems
through [issues](../../issues) or, for security, [SECURITY.md](SECURITY.md).

## Uninstall

1. If you turned on **Open at login**, turn it off in the app's Settings.
2. In the folder you installed from, run:
   ```bash
   ./uninstall.sh
   ```

It asks before it does anything. It quits the app, then removes the app, its settings and backup
records (`~/Library/Containers/io.github.ilterkavlak.blobshelf` and
`~/Library/Application Scripts/io.github.ilterkavlak.blobshelf`), and the bucket tokens in your
Keychain. Nothing in your buckets or backed-up folders is deleted. Afterwards you can delete the
source folder too.

## License

[MIT](LICENSE). Upstash is a trademark of its owner; this project is not affiliated with or
endorsed by Upstash.
