# Building StoryReader (Android focus)

Every command below was run on this machine (Arch/Hyprland) and the APK builds verified,
2026-10-26.

## Toolchain

| Piece | Location / version |
|---|---|
| Flutter SDK (stable, **pinned**) | `~/development/flutter` — tag `3.35.7`, Dart 3.9.2 |
| Android SDK | `~/Android/Sdk` — platforms;android-36, build-tools;36.0.0, cmake;3.22.1 (ndk;27.0.12077973 also installed, not needed by this app) |
| JDK | system OpenJDK 21 (`/usr/bin/java`) |
| Gradle | 8.9 via `android/gradle/wrapper` (untouched; wrapper downloads it) |

**The build needs no tracked-file changes at all** (verified: clean tree, release split-per-abi
APKs in 167 s).

```sh
export PATH="$HOME/development/flutter/bin:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
```

### Why Flutter 3.35.7 and not current stable

Newer Flutter (checked: 3.47.8 / Dart 3.13.7) does **not** build this repo as committed:

1. Codegen dies: the pinned `analyzer` 2.x cannot parse the newer SDK sources
   (`Exception: Missing implementation of visitDotShorthandPropertyAccess`), after which
   `build_runner` sits at ~1% CPU forever.
2. Upgrading dependencies (`flutter pub upgrade --major-versions`) does fix that (analyzer → 14.6,
   `build_runner` finishes in 23 s, `flutter analyze` → 0 errors) but then Flutter demands
   Gradle ≥ 9.1 / AGP ≥ 9.0.1 / Kotlin ≥ 2.2.20, i.e. the AGP-9 "new DSL" migration of
   `android/**/*.gradle` — a real fork-maintenance change on top of the feature work.

On 3.35.7 there are **zero source changes needed**: original `pubspec.lock`, original Gradle
files, upstream code compiles as-is. The dependency/codegen upgrade is still worth doing, but as
its own deliberate step (`EXPANSION.md` step 1), not as build plumbing.

To stay pinned: `cd ~/development/flutter && git checkout 3.35.7` (detached tag checkout;
`flutter upgrade` would undo it).

One-time machine setup that was needed:

```sh
flutter config --android-sdk ~/Android/Sdk && yes | flutter doctor --android-licenses
sdkmanager "platforms;android-36" "build-tools;36.0.0"   # Flutter needs SDK 36 / BT 36; box had 34
```
(cmake;3.22.1 gets installed automatically by `flutter build` when a native plugin needs it.)

## Build steps

```sh
cd ~/Development/StoryReader
export PATH="$HOME/development/flutter/bin:$PATH" ANDROID_HOME="$HOME/Android/Sdk"

dart run build_runner build --delete-conflicting-outputs  # drift + chopper + json_serializable
flutter gen-l10n                                          # lib/l10n/localizations.dart (gitignored)
flutter analyze                                           # 0 errors, 44 infos/warnings
flutter build apk --debug                                 # 95 s → build/app/outputs/flutter-apk/app-debug.apk (146 MB: all ABIs + debug)
flutter build apk --release --split-per-abi               # per-ABI APK for a real device
```

Install on a device: `flutter install --debug`, or sideload the arm64 release APK.
There are no real tests to run (`test/` is one empty file plus a live-network print script).

## Release signing (still the debug key — deliberate for now)

`android/app/build.gradle` signs `release` with **debug keys** (upstream TODO, kept for the fork
until a real release channel exists). Consequences of signing releases with the debug key at
`~/.android/debug.keystore`:

- **Sideloaded updates only install when the APK was built on this machine**, because that is the
  machine whose `~/.android/debug.keystore` signs them. An APK built elsewhere has a different
  debug key → signature mismatch → uninstall (losing app data) before install.
- **Back up `~/.android/debug.keystore`** (and keep it out of the repo). It is currently the only
  thing tying every installable build of this fork together.

For a real fork release later:

```sh
keytool -genkey -v -keystore storyreader-keystore.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias storyreader
```
then a gitignored `key.properties` + `signingConfigs.release` in `android/app/build.gradle`.

## Package id (done: the fork has its own id)

The fork installs **beside** the upstream F-Droid app:

| | upstream | fork |
|---|---|---|
| `applicationId` | `io.github.tareksander.StoryReader` | `io.github.urbanslayer.storyreader` |
| launcher label | StoryReader | StoryReader+ |
| DB schema | 10 | 11+ (`lib/db.dart`) |

The Kotlin `namespace`/package (`com.tsander.story_reader`) and `MainActivity` stay as they are —
changing them only requires moving files and gains nothing (nothing references the old
applicationId in Kotlin/XML).

Because both apps coexist, the user's real library moves via the built-in *share/receive over
local network* transfer: **old app = sender** (Share page), **fork = receiver** (Load page). The
fork's Load page has a *Source app* picker; "Original StoryReader" sends `X-Schema: 10` and runs
`AppDB.importLegacyV10Library` (`lib/db.dart`), which converts the v10 payload and applies the
same repairs as the v10→v11 migration (drop v10's content-less `''` dummy rows, rename
content-bearing `''` rows to `legacy-<number>`, dedupe duplicate `chapterID`s, backfill
`position`/`chapterNumber`, promote `lastRead` to `lastReadChapterID`). The sender answers exactly
**one** request per sharing session (even a rejected one, `used` is set first), so the schema
version must be chosen correctly **before** pressing Load; if a transfer was rejected, restart the
Share page on the source app before retrying. Fork→fork transfers keep using the unchanged
same-schema `replaceDB` path.

## Repo map (Android-relevant)

- `lib/db.dart` (556 L) — drift DB: `series`, `chapters`, `images`, schema v10 + all migrations.
- `lib/sh.dart` / `lib/rr.dart` — ScribbleHub / RoyalRoad scrapers (chopper + `html`).
  ScribbleHub TOC comes from the `wi_gettocchp` admin-ajax endpoint, chapter HTML from `/read/…`.
- `lib/rich_text_tree.dart` (767 L) — lossy RichText tree (JSON, gzip'd, stored per chapter).
- `lib/download_manager.dart` — background isolate that drains the `queued` flags.
- `lib/pages/*` — library / series / read / search / settings / network-transfer UI.
- `flutter_riverpod` is used only for `ProviderScope` in `main.dart`, so riverpod 2 → 3 is a no-op
  for this code.
- No real tests: `test/sh_test.dart` is empty, `test/rr_test.dart` is a live-network print script.
