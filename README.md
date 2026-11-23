# JetBird iOS

Multi-part download manager and PS4 companion for iOS.
Port of [nueex/JetBird](https://github.com/nueex/JetBird) (GPL-3.0-or-later).

## What is implemented

| Feature | Status | Notes |
|---------|--------|-------|
| Multi-part downloads (1-8 parts) | Implemented | `URLSession` + HTTP Range, pause/resume, queue, optional SHA-256 check |
| Save to Files app | Implemented | Files go to `Documents/JetBird/<Category>/` (file sharing enabled) |
| Ad-blocking browser | Implemented | `WKContentRuleList`, bundled lists in `Resources/filters` |
| Download detection in browser | Implemented | Attachments / non-displayable files, cookies are forwarded |
| SPAKE2 pairing (P-256) | Implemented | Rust core (`rust-core/`) linked as an XCFramework |
| QR code pairing | Implemented | VisionKit `DataScannerViewController` (supported devices only) |
| Bonjour discovery of the PS4 | Implemented | `_psmtp._tcp` |
| Direct download hand-off to the PS4 | Implemented, untested | Message format follows the Android app; not verified on a real console |
| Parallel PKG install | Not implemented | The protocol message types exist, streaming does not |
| Background downloads | Limited | Downloads continue for a short time after leaving the app (background task) but are not durable across app termination |
| Localization | Russian + English | Switch in Settings (default: Russian) |
| Download folder | Implemented | Default: Files > On My iPhone > JetBird; any folder can be chosen in Settings |
| App icon | Implemented | `Resources/Assets.xcassets` |

## Project layout

```
rust-core/            Rust SPAKE2 library + build.sh -> Frameworks/JetBirdSpake2.xcframework
Sources/App/          Swift app (single module: Core + UI)
Resources/            Ad-block rule lists, asset catalog (app icon), ru/en strings
Config/Info.plist     App Info.plist
project.yml           XcodeGen spec (the .xcodeproj is generated, not committed)
.github/workflows/    CI: builds an unsigned .ipa
```

There are no third-party Swift package dependencies.

## Build locally

Requirements: macOS, Xcode 16+, Rust (rustup), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
(cd rust-core && ./build.sh)      # creates Frameworks/JetBirdSpake2.xcframework
xcodegen generate                 # creates JetBird.xcodeproj
open JetBird.xcodeproj
```

## CI

Pushing a tag `v*` (or running the workflow manually) builds an unsigned `JetBird.ipa`
and uploads it as an artifact; tag builds also create a GitHub release.
The `.ipa` is unsigned: sign it yourself (e.g. with a sideloading tool) to install it.

## License

GPL-3.0-or-later
