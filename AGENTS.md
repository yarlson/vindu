# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Project

vindu — a dynamic tiling window manager for macOS (repo: github.com/yarlson/vindu; the folder name "macland" is the project's old name, kept intentionally). SwiftPM, macOS 13+, one exact-pinned TOML dependency. Five targets: `VinduCore` (pure logic), `VinduDaemonSupport` (testable daemon support), `VinduBorderEngine` (internal C border integration), `vindud` (daemon), and `vinductl` (CLI).

## Architecture docs

Current-state docs live in `docs/context/` — index at `docs/context/context-map.md`:

- `summary.md` — architecture, core flow; read before structural work
- `practices.md` — binding invariants (geometry origin, threading, membership APIs), configuration contract, platform constraints, conventions; read before changing daemon or layout behavior
- `terminology.md`, `domains/*` (config, layout, workspaces, window-management, input, ipc), `platform/distribution.md` (CI, release pipeline)

These docs describe current state only. When a change affects something they cover, update them in the same change — no changelogs, no history.

## Commands

- `make build` — debug build
- `make test` — run all tests (swift-testing). Always use this instead of bare `swift test`: on machines with Command Line Tools but no Xcode it injects the framework search paths Testing.framework needs. Without them, `swift test` exits 0 having run zero tests — a silent false green.
- Single suite: `swift test --filter LayoutTests`, adding the same `-Xswiftc`/`-Xlinker` flags from the Makefile on a CLT-only machine.
- `make release` — release build + ad-hoc codesign (stable code identity keeps the user's Accessibility grant across rebuilds)
- `make check-template` — verifies `examples/vindu.toml` is byte-identical to the template in `Sources/vindud/DefaultConfig.swift` (also runs as part of `make test`)

## Rules

- Never run `vindud` yourself: it re-tiles the user's real windows. Verify daemon behavior only with explicit user consent; pure logic belongs in `VinduCore` where `make test` covers it.
- Keep private WindowServer calls inside `VinduBorderEngine` and load them dynamically from the fixed system framework path. A missing symbol or reported setup or runtime failure must disable only the border. Never link `vindud` directly to SkyLight.
- Never change the version (`VinduVersion`) unless explicitly asked.
- Keep user-facing strings focused on Vindu. Mention legacy behavior only where a migration or retained public protocol requires it.
