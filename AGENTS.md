# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Project

vindu — a dynamic tiling window manager for macOS (repo: github.com/yarlson/vindu; the folder name "macland" is the project's old name, kept intentionally). SwiftPM, macOS 13+, zero external dependencies. Three targets: `VinduCore` (pure logic, the only tested target), `vindud` (daemon), `vinductl` (CLI).

## Architecture docs

Current-state docs live in `docs/context/` — index at `docs/context/context-map.md`:

- `summary.md` — architecture, core flow; read before structural work
- `practices.md` — binding invariants (geometry origin, threading, membership APIs), Hyprland compat policy, platform constraints, conventions; read before changing daemon or layout behavior
- `terminology.md`, `domains/*` (config, layout, workspaces, window-management, input, ipc), `platform/distribution.md` (CI, release pipeline)

These docs describe current state only. When a change affects something they cover, update them in the same change — no changelogs, no history.

## Commands

- `make build` — debug build
- `make test` — run all tests (swift-testing). Always use this instead of bare `swift test`: on machines with Command Line Tools but no Xcode it injects the framework search paths Testing.framework needs. Without them, `swift test` exits 0 having run zero tests — a silent false green.
- Single suite: `swift test --filter LayoutTests`, adding the same `-Xswiftc`/`-Xlinker` flags from the Makefile on a CLT-only machine.
- `make release` — release build + ad-hoc codesign (stable code identity keeps the user's Accessibility grant across rebuilds)
- `make check-template` — verifies `examples/vindu.conf` is byte-identical to the template in `Sources/vindud/DefaultConfig.swift` (also runs as part of `make test`)

## Rules

- Never run `vindud` yourself: it re-tiles the user's real windows. Verify daemon behavior only with explicit user consent; pure logic belongs in `VinduCore` where `make test` covers it.
- Never change the version (`VinduVersion`) unless explicitly asked.
- Keep user-facing strings (README lead, CLI output, notifications) Hyprland-free; Hyprland is named only as a migration aid. Full policy in `docs/context/practices.md`.
