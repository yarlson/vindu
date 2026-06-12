# Practices

## Invariants

- All geometry is top-left-origin global coordinates (CG/AX space); `up` means decreasing y. Convert to AppKit's bottom-left origin only at the last boundary (border-overlay frame, `cursorpos` reply).
- The window manager is single-threaded on the main queue. Tap callbacks, IPC reads, and timers hop to main before touching state.
- Tiled membership changes only through `WorkspaceState.insertTiled/removeTiled/removeWindow/swapTiled` — the single place that keeps master order and the dwindle tree in lockstep. Layout-specific APIs (ratios, mfact, orientation) never change membership.
- Master order is the canonical window order; the dwindle tree is rebuilt from it when the layout switches.
- Config errors never crash the daemon: they are collected with line numbers, readable via `configerrors`, and surfaced as a user notification.
- The default config template ships inside the binary (`DefaultConfig.swift`); `examples/vindu.conf` must stay byte-identical. `make test` enforces this (`check-template`).
- One daemon per user: the command socket file is probed before bind — a live listener aborts startup, a dead file is unlinked.

## Hyprland compatibility policy

- Compatible surfaces: config dialect, dispatcher names, IPC verbs and JSON shapes, event wire format, id schemes (negative named/special workspace ids, hex window addresses).
- Tolerance has tiers: whole sections with no macOS counterpart are accepted wholesale; a fixed list of known Hyprland keys inside modeled sections is accepted silently; everything else errors so typos stay visible. The same idea applies to rule effects (an `unsupported` set) and IPC verbs (explicit "no macOS equivalent" replies).
- Branding: user-facing strings (README lead, CLI output, notifications) stay Hyprland-free; Hyprland is named only as a migration aid. Code comments documenting Hyprland-derived semantics are fine.

## Platform constraints

- SIP stays on; the WindowServer is closed. Animations, blur, per-window opacity, rounded clipping of other apps' windows, and a click-to-kill picker are deliberately impossible — features must not assume compositor access.
- Workspace hiding is frame-stashing, not Space membership; anything repositioning windows must respect the `hidden` and `nativeFullscreen` flags.
- Swift language mode 5 (under tools 6.0): the daemon passes callback pointers to C APIs (AX observers, CGEvent taps) that Swift 6 strict concurrency cannot model usefully.
- The Accessibility grant is tied to code identity: release/install builds are ad-hoc signed so rebuilds of the same tree keep the grant; a genuinely new binary needs a re-toggle in System Settings.

## Testing and verification

- All logic that can be pure lives in VinduCore and is tested with swift-testing; the daemon is the untestable shell. New logic lands in VinduCore when feasible.
- `make test` injects Command Line Tools framework paths so `swift test` works without full Xcode.
- The daemon re-tiles the user's real windows; runtime verification needs a live session and explicit user consent.

## Conventions

- Parse failures return `Result<_, ParseError>` or optionals with short messages; `ParseError` is string-interpolation-expressible so parse code returns `.failure("…")` directly.
- Settings keywords live in one option table driving both `set` (validation, ranges) and `get` (IPC `getoption`); new options are added there, not as ad-hoc parsing.
- IPC replies are `ok`, payload text/JSON, or `err: …`; vinductl derives its exit code from that prefix.
- The version string lives in `VinduVersion` and changes only on an explicit release decision.
