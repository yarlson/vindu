# Build, release, distribution

## Local build

- SwiftPM only: `make build` (debug), `make release` (release plus codesign), `make install` (to PREFIX, default `/usr/local`). `VINDU_CODESIGN_IDENTITY` selects a persistent certificate; its default `-` produces an ad-hoc signature.
- `make test` runs `swift test`, injecting Command Line Tools framework and rpath flags when `Testing.framework` only exists in the CLT location — tests work without full Xcode.
- `make test` also enforces the template invariant: the config template embedded in `DefaultConfig.swift` must be byte-identical to `examples/vindu.conf`.

## Code identity

macOS ties the Accessibility grant to the binary's designated requirement. Vindu signs `vindud` as `com.vindu.daemon` and `vinductl` as `com.vindu.control`. A persistent certificate plus these stable identifiers lets a rebuilt binary satisfy the prior requirement. An ad-hoc signature identifies only one build, so its replacement requires re-toggling `vindud` in System Settings. Local release and install builds use `VINDU_CODESIGN_IDENTITY`, which defaults to ad-hoc signing for compatibility. Two daemons must never run at once (brew service plus a dev build fight over the same windows); the command-socket probe enforces single instance.

## Service management

`vindud --install-service` writes a LaunchAgent (`com.vindu.daemon`) pointing at the current binary and bootstraps it via launchctl: runs at load, kept alive unless it exits cleanly, and logs to `~/Library/Logs/vindu/vindud.log`. If `--config <path>` is provided, the LaunchAgent stores that resolved path in `ProgramArguments`. `--uninstall-service` reverses it. Reinstalls boot the old instance out first so they cannot fail on an already-loaded service. Homebrew users get the same lifecycle via `brew services`; the formula creates the same private per-user log directory.

## CI

Build-and-test matrix on the oldest and newest macOS runner images (both Apple Silicon), with a SwiftPM cache keyed by source revision, manifest, and image. A release-configuration build plus `--version` smoke runs catch optimizer-only breakage and prove the binaries start.

## Release pipeline

Pushing a `v*` tag drives the entire release:

1. Per-triple release builds are lipo'd into universal (arm64 + x86_64) binaries. Per-triple because `swift build` with multiple `--arch` flags requires Xcode's xcbuild.
2. When Developer ID and notary secrets are present, the binaries are Developer ID signed with stable identifiers, hardened runtime, and timestamp, packaged as a ZIP, submitted to Apple notarization, and verified with `codesign`, `spctl`, checksum, identifier, and binary smoke checks. If secrets are absent, CI publishes an explicitly labeled per-build ad-hoc fallback ZIP and does not update Homebrew.
3. The ZIP ships the binaries, README, and the example config; sha256 checksums and a build-provenance attestation accompany it (verifiable with `gh attestation verify`).
4. A GitHub release is created with notes that state whether the artifact is notarized.
5. The published asset is round-tripped — downloaded from the release URL, checksum-verified, executed, architecture-checked, and Developer ID/hardened-runtime checked when applicable — before anything points at it.
6. The Homebrew formula is rendered from `packaging/vindu.rb.tmpl` (tag, version, sha substitution), syntax-checked, and pushed to `yarlson/homebrew-tap` only for notarized artifacts. Release actions are pinned to immutable SHAs, and the tap checkout uses a scoped token without embedding it in the clone URL or persisting it in `.git/config`. The template in this repo is the formula's source of truth.

Notarization and hardened runtime are distribution-integrity checks, not sandboxing; `vindud` remains an unsandboxed Accessibility/event-tap daemon.

The version constant (`VinduVersion`) and the git tag are kept in step by the release decision; nothing derives the version from anything else.
