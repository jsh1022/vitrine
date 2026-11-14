# Vendored app-local WireGuard engine

Copied from `WireGuard/` in the user-provided `BitChord-iOS-main.zip`.
Archive SHA-256: `60ae70958cfa1ce068913156af8221e6c74a004498a01cf4a115c94d8ab147e7`.
The supplied archive's project license is GPL-3.0 (`COPYING`). Its pinned dependency
licenses remain in `THIRD_PARTY_LICENSES.txt`. The module and engine sources are
preserved; Vitrine's integration lives in `Shared/AudioSources/SGWireGuard.m`.

This is wireguard-go and gVisor netstack behind an authenticated loopback SOCKS5
proxy. It does not install a system VPN, change routes or require Network Extension
entitlements. Vitrine applies it to its own addon sessions only. Spotify's own
network stack is unchanged. The engine's original YouTube-oriented classification
counters are retained for provenance and are not used for Vitrine routing.

Build from a Mac with Go matching `go.mod`, Xcode and an iPhoneOS SDK:

```sh
MIN_IOS=16.0 bash vendor/wireguard/build-ios.sh
```

On Linux, `IOS_SDK` and `CLANG` can select an iPhoneOS SDK and an Apple-target-capable
compiler. iOS URLSession SOCKS5 configuration still requires iOS 17 at runtime.
The parser accepts one peer, numeric DNS, an IPv4 default route and (for a dual-stack
profile) an IPv6 default route. Script hooks, split-only routes and unknown profile
directives are rejected. A hostname peer endpoint is resolved outside the tunnel
once during startup; destination DNS stays inside it.

Run the isolated engine tests with `go test -race ./...` in this directory. Tests
use generated keys and local peers, DNS and HTTPS servers. No real profile, media
service, account or credential is included.
