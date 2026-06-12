# Build, release, distribution

## Local build

- SwiftPM only: `make build` (debug), `make release` (release plus ad-hoc codesign), `make install` (to PREFIX, default `/usr/local`).
- `make test` runs `swift test`, injecting Command Line Tools framework and rpath flags when `Testing.framework` only exists in the CLT location — tests work without full Xcode.
- `make test` also enforces the template invariant: the config template embedded in `DefaultConfig.swift` must be byte-identical to `examples/vindu.conf`.

## Code identity

macOS ties the Accessibility grant to the binary's code identity. Release and install builds are ad-hoc signed so rebuilds of the same source tree keep the grant; a genuinely new binary requires re-toggling vindud in System Settings. Two daemons must never run at once (brew service plus a dev build fight over the same windows); the command-socket probe enforces single instance.

## Service management

`vindud --install-service` writes a LaunchAgent (`com.vindu.daemon`) pointing at the current binary and bootstraps it via launchctl: runs at load, kept alive unless it exits cleanly, logs to `/tmp/vindu.log`. `--uninstall-service` reverses it. Reinstalls boot the old instance out first so they cannot fail on an already-loaded service. Homebrew users get the same lifecycle via `brew services`.

## CI

Build-and-test matrix on the oldest and newest macOS runner images (both Apple Silicon), with a SwiftPM cache keyed commit → manifest → image. A release-configuration build plus `--version` smoke runs catch optimizer-only breakage and prove the binaries start.

## Release pipeline

Pushing a `v*` tag drives the entire release:

1. Per-triple release builds are lipo'd into universal (arm64 + x86_64) binaries and ad-hoc signed. Per-triple because `swift build` with multiple `--arch` flags requires Xcode's xcbuild.
2. The tarball ships the binaries, README, and the example config; sha256 checksums and a build-provenance attestation accompany it (verifiable with `gh attestation verify`).
3. A GitHub release is created with generated notes.
4. The published asset is round-tripped — downloaded from the release URL, checksum-verified, executed, architecture-checked — before anything points at it.
5. The Homebrew formula is rendered from `packaging/vindu.rb.tmpl` (tag, version, sha substitution), syntax-checked, and pushed to `yarlson/homebrew-tap`. The template in this repo is the formula's source of truth.

The version constant (`VinduVersion`) and the git tag are kept in step by the release decision; nothing derives the version from anything else.
