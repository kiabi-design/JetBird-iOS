# JetBird iOS

**Fast multi-part download manager & PS4 companion for iOS**

Port of [nueex/JetBird](https://github.com/nueex/JetBird) (GPL-3.0-or-later) from Android to iOS.

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| Multi-part downloads (1-8 parts) | ✅ | `URLSession` with range requests |
| Wireless Transfer (Wi-Fi + SPAKE2) | ✅ | Full port of SPAKE2 (RFC 9382) |
| Direct PS4 Download handoff | ✅ | Send HTTPS links to PS4 |
| Parallel PKG Install | ✅ | Stream to PS4 installer |
| Ad-blocking browser | ✅ | `WKContentRuleList` (native, fast) |
| Background downloads | ✅ | `BGProcessingTask` + background `URLSession` |
| QR code pairing | ✅ | VisionKit scanner |
| 7 languages + RTL | ✅ | SwiftUI localization |
| Save to Files app | ✅ | FileProvider integration |

## Architecture

```
JetBird iOS
├── rust-core/                 # Rust SPAKE2 implementation
│   ├── src/
│   │   ├── lib.rs            # FFI entry points
│   │   ├── spake2.rs         # P-256 EC operations (p256 crate)
│   │   ├── hmac.rs           # HMAC-SHA256 + HKDF
│   │   ├── constants.rs      # M/N points from Android
│   │   └── transcript.rs     # Transcript building
│   ├── include/
│   │   └── jetbird_spake2.h  # C header for Swift
│   └── build.sh              # → JetBirdSpake2.xcframework
│
├── Sources/
│   ├── JetBirdCore/          # Core logic (Swift)
│   │   ├── Models/           # DownloadInfo, PS4Connection, etc.
│   │   ├── Crypto/           # Spake2Manager (Swift wrapper)
│   │   ├── Protocol/         # PSMTPProtocol, PSMTPConnection
│   │   ├── DownloadManager/  # Multi-part download engine
│   │   └── Browser/          # ContentFilterEngine (ad-block)
│   │
│   ├── JetBirdUI/            # SwiftUI views
│   │   ├── Views/            # ContentView, BrowserView, etc.
│   │   └── ViewModels/       # AppSettingsStore, BrowserViewModel
│   │
│   └── JetBirdApp/           # App entry point
│       └── JetBirdApp.swift  # @main
│
├── Package.swift             # Swift Package Manager
├── build.sh                  # Full build script
└── README.md
```

## Requirements

- **macOS 14+** (Sonoma)
- **Xcode 15+** / **Swift 5.9+**
- **Rust 1.75+** (for core)
- **iOS 16+** target
- **PS4** with jailbreak + [PS MTP Explorer 3.0+](https://github.com/nueex/ps-mtp-explorer)

## Building

### 1. Install Rust targets
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

### 2. Build everything
```bash
cd JetBird-iOS
./build.sh
```

This will:
1. Compile Rust core for iOS targets → `Frameworks/JetBirdSpake2.xcframework`
2. Build Swift package
3. Generate `JetBird.xcodeproj`

### 3. Open in Xcode
```bash
open JetBird.xcodeproj
```

### 4. Run
- Select your device/simulator
- Press **Cmd+R**

## Project Structure Details

### Rust Core (SPAKE2)

Direct port of `native/lan_spake.c` from Android:

- **Curve**: P-256 (secp256r1) via `p256` crate
- **SPAKE2**: RFC 9382, symmetric variant
- **M/N points**: Hardcoded from Android implementation
- **Memory safety**: `zeroize` + `ZeroizeOnDrop`
- **Constant-time**: `subtle` crate for comparisons
- **FFI**: C-compatible API for Swift

### Swift Core

#### DownloadManager
- Multi-part downloads with resume
- Background `URLSession` support
- Progress reporting via async streams
- Automatic part merging + verification

#### PSMTPProtocol
- TLS 1.3 with certificate pinning
- SPAKE2 authentication flow
- Message framing (type + sequence + length + payload)
- Direct download handoff
- Parallel PKG install streaming

#### ContentFilterEngine
- `WKContentRuleList` for native ad-blocking
- EasyList / EasyPrivacy / uBlock Origin compatible
- Periodic auto-update from upstream

### SwiftUI App

Three tabs:
1. **Downloads** - Queue management, progress, swipe actions
2. **Browser** - Tabs, address bar, ad-block, download detection
3. **Transfers** - PS4 discovery, pairing, direct download

## Pairing Flow

```
iPhone (Phone)                    PS4 (Console)
     │                                  │
     ├─ SPAKE2: code=123456, pin ──────►│
     │                                  │
     │◄─ SPAKE2: their_point, proofs ───┤
     │                                  │
     ├─ Verify proofs, derive key ──────►│
     │                                  │
     └──── TLS 1.3 (session_key) ──────►│
```

QR code format: `jetbird://pair?code=123456&pin=<base64>`

## License

GPL-3.0-or-later (same as upstream JetBird)

Third-party licenses:
- `p256`, `sha2`, `hmac`, `hkdf`, `subtle`, `zeroize` - MIT/Apache-2.0
- Swift packages - various (see `Package.swift`)

## Credits

- **Original Android**: [nueex/JetBird](https://github.com/nueex/JetBird)
- **PS MTP Explorer**: [nueex/ps-mtp-explorer](https://github.com/nueex/ps-mtp-explorer)
- **SPAKE2 RFC 9382**: IETF
- **BearSSL**: TLS/crypto reference (Android)

## Status

**Active development** - Core functionality implemented, UI polishing in progress.

See [GitHub Issues](https://github.com/nueex/JetBird/issues) for tracking.