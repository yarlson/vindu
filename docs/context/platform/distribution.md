# Build, release, distribution

## Local build

- SwiftPM only: `make build` (debug), `make release` (release plus ad-hoc codesign), `make install` (binaries and third-party notices under PREFIX, default `/usr/local`).
- `VinduBorderEngine` is an internal C target linked into `vindud`. Its private WindowServer calls are dynamically resolved at runtime, so the binary has no SkyLight load command or direct private-symbol imports.
- `make test` runs the Swift suite and a sanitizer-backed C harness for border callback lifetime, advisory transaction returns, and invalid geometry. It injects Command Line Tools framework and rpath flags when `Testing.framework` only exists in the CLT location, so tests work without full Xcode.
- `make test` also enforces the template invariant: the config template embedded in `DefaultConfig.swift` must be byte-identical to `examples/vindu.toml`.

## Code identity

macOS ties the Accessibility grant to the binary's code identity. Release and install builds are ad-hoc signed so rebuilds of the same source tree keep the grant; a genuinely new binary requires re-toggling vindud in System Settings. Two daemons must never run at once (brew service plus a dev build fight over the same windows); the command-socket probe enforces single instance.

## Service management

`vindud --install-service` writes a LaunchAgent (`com.vindu.daemon`) pointing at the current binary and bootstraps it via launchctl: it runs at load, stays alive unless it exits cleanly, and logs to `~/Library/Logs/vindu/vindud.log`. A default-path install omits `--config`, so every start uses the native selection rules and can create the canonical TOML file. If `--config <path>` is provided, the LaunchAgent stores that resolved path in `ProgramArguments`. Reinstall a service created by an older build that stored the old default path. `--uninstall-service` reverses the installation. Reinstalls boot the old instance out first so they cannot fail on an already-loaded service. Homebrew users get the same lifecycle through `brew services`; the formula installs `vindu.toml` and creates the same private per-user log directory.

## CI

Build-and-test matrix on the oldest and newest macOS runner images (both Apple Silicon), with a SwiftPM cache keyed by source revision, manifest, and image. A release-configuration build plus `--version` smoke runs catch optimizer-only breakage and prove the binaries start. CI proves the macOS 13 deployment build, pure border policy, and fake-symbol lifecycle and failure paths, but private border capability, drawing, input transparency, and event timing require a real logged-in window session on each supported macOS version.

## Release pipeline

Pushing a `v*` tag drives the entire release:

1. The tag must use `vX.Y.Z`, resolve to the workflow commit, match the version reported by both binaries, and have no existing GitHub release. The workflow also requires access to the Homebrew tap before it publishes anything.
2. Per-triple release builds are lipo'd into universal (arm64 + x86_64) binaries and ad-hoc signed. Per-triple because `swift build` with multiple `--arch` flags requires Xcode's xcbuild.
3. The ZIP ships the binaries, README, third-party notices, and `examples/vindu.toml`; sha256 checksums and a build-provenance attestation accompany it (verifiable with `gh attestation verify`).
4. The Homebrew formula is rendered from `packaging/vindu.rb.tmpl` (tag, version, sha substitution) and passes Ruby syntax and Homebrew style checks before the GitHub release is created.
5. The published asset is round-tripped — downloaded from the release URL, checksum-verified, executed, architecture-checked, and signature-checked — before anything points at it.
6. The prepared formula is pushed to `yarlson/homebrew-tap`. Release actions are pinned to immutable SHAs, and the tap checkout uses a scoped token without embedding it in the clone URL or persisting it in `.git/config`. The template in this repo is the formula's source of truth.

If any step fails after GitHub publication, leave the tag and release assets unchanged. Verify the published ZIP against `checksums.txt`, then check both binaries' versions, architectures, and signatures. Render the formula from the tagged template and published checksum, validate it, and update only the tap.

The version constant (`VinduVersion`) and the git tag are kept in step by the release decision; nothing derives the version from anything else.
