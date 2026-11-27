# JetBird iOS

Download manager and PS4 companion for iOS. Unofficial iOS port of
[nueex/JetBird](https://github.com/nueex/JetBird) (GPL-3.0-or-later) for the
PS4 homebrew app *PS MTP Explorer*.

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| Multi-part downloads (1-8 parts) | Implemented | `URLSession` + HTTP Range, pause/resume, queue, optional SHA-256 check |
| Save to Files app / custom folder | Implemented | Default: Files > On My iPhone > JetBird; any folder can be chosen in Settings |
| Ad-blocking browser | Implemented | `WKContentRuleList`; the bundled lists in `Resources/filters` are small samples |
| Download detection in the browser | Implemented | Attachments / non-displayable files; cookies, referer and user agent are forwarded |
| Wireless pairing with the PS4 by QR code | Implemented | QR format `PSMTP1:<ip>:<64 hex>` |
| Wireless pairing with a six-digit code | Implemented | "Request six-digit code" button, SPAKE2 (RFC 9382, P-256) |
| Direct PS4 Download (the console fetches an HTTPS link itself) | Implemented | Protocol ported from the Android app; "install as PKG" supported |
| PS4 free-space display | Implemented | |
| FTP file manager for the PS4 | Implemented | Own passive-mode FTP client (e.g. GoldHEN FTP, port 2121): browse, download files/folders, upload, new folder, rename, delete |
| USB transfer, streaming a download through the phone to the PS4, resumable PS4 transfers | Not implemented | |
| Background downloads | Limited | Continue for a short time after leaving the app; not durable across app termination |
| Languages | Russian / English | Switch in Settings (default: Russian) |

## Protocol (from the Android app)

* TCP port `41984`, TLS 1.2. The console certificate is pinned by the first 16 bytes of its SHA-256.
* QR pairing: pin (16 bytes) + secret (16 bytes). Hello: `PSL1 | secret | transfer-flag` -> `PSR1 | status`.
* Six-digit pairing: TLS, `PSM3`, console SPAKE2 point (65 bytes); the phone answers with its point and a
  proof, the console returns its proof and the 16-byte secret. The crypto is the original C code
  (`native/lan_spake.c` + BearSSL), unchanged.
* Direct download: `PSL1`/`PSL2` (install) header with file name and size, then
  `url NUL user-agent NUL referer NUL cookie NUL`.

## Project layout

```
Sources/App/          Swift app (single module: Core + UI)
Resources/            Asset catalog (icon), ru/en strings, ad-block lists
native/               SPAKE2 (C) from nueex/JetBird
third_party/bearssl/  The BearSSL files needed by SPAKE2 (MIT)
Config/Info.plist     App Info.plist
project.yml           XcodeGen spec (the .xcodeproj is generated, not committed)
.github/workflows/    CI: builds an unsigned .ipa
```

There are no third-party Swift packages and no Rust code.

## Build locally

Requirements: macOS, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open JetBird.xcodeproj
```

## CI

Pushing a tag `v*` (or running the workflow manually) builds an unsigned `JetBird.ipa` and uploads it as an
artifact; tag builds also create a GitHub release. The `.ipa` is unsigned: sign it yourself to install it.

## License

GPL-3.0-or-later. Includes BearSSL (MIT, see `third_party/bearssl/LICENSE.txt`) and code from nueex/JetBird.
