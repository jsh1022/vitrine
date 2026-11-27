# Hosted media transforms

This directory builds the small, static FFmpeg subset used to prepare the
Deezer hosted lossless responses. Vitrine's Objective-C adapter is
`tweak/Sources/Shared/AudioSources/SGHostedMedia.m`; the existing addon client handles downloads and
provider metadata, while this library supplies local cryptographic primitives. It has no network or executable tools enabled.

## Build

`build.sh` downloads the upstream FFmpeg 9.0.2 release archive and checks its
SHA-256 before extracting it:

```text
https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
```

The build enables only the MOV demuxer, FLAC muxer, FLAC parser and decoder,
file protocol, and zlib. Network, autodetection, programs, shared libraries,
and unrelated codecs and components are disabled. No source patches are
applied. The script supports `PLATFORM=ios` (arm64, minimum iOS 16),
`PLATFORM=simulator` (minimum iOS 17), and `PLATFORM=macos` (minimum macOS 13).
For example, run `PLATFORM=simulator bash vendor/hosted-media/build.sh` from the
repository root on a Mac with Xcode command-line tools installed. Build output
and downloaded source are kept under this directory's ignored `build/` folder.

## Media handling

- Deezer's supported encrypted FLAC form is decrypted locally using its
  Blowfish-CBC scheme (encrypted blocks of three 2048-byte chunks). During
  downloads, complete blocks are decrypted immediately; an incomplete block
  of at most 2047 bytes is buffered and the final short tail remains clear.
  The contiguous clear prefix can be measured by the native FLAC decoder
  before download completion. The result is not re-encoded.
- A raw FLAC response is kept unchanged. Only stereo FLAC is accepted; lossy
  codecs and Atmos/multichannel audio are rejected.
- The complete-file transform API uses a bounded local file (128 MiB), honor cancellation, write to
  a temporary file, and replace the downloaded original atomically only after
  successful completion. The application does not log media keys.

These are implementation constraints, not evidence that provider credentials
or live server media have been verified. Actual authentication and provider
audio responses remain unconfirmed.

## License

FFmpeg is distributed under LGPL 2.1 or later for this configured build.
The corresponding license text is included as `COPYING.LGPLv2.1`. The build
uses the unmodified upstream 9.0.2 source archive identified above.
