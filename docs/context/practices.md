# Practices

## Invariants

- All window and border geometry uses top-left-origin global coordinates; `up`
  means decreasing y. Convert to AppKit's bottom-left origin only at AppKit UI
  and `cursorpos` reply boundaries.
- The window manager is single-threaded on the main queue. Tap callbacks, IPC
  reads, watcher callbacks, and timers hop to main before touching runtime state.
- Tiled membership changes only through
  `WorkspaceState.insertTiled/removeTiled/removeWindow/swapTiled`, which keeps
  master order and the dwindle tree in lockstep. Layout ratios and orientation do
  not change membership.
- Master order is the canonical window order. The dwindle tree is rebuilt from it
  when the active layout changes.
- The runtime consumes one immutable `ConfigurationSnapshot`. A candidate replaces
  it only after the whole file decodes and passes semantic validation. A failed
  reload preserves the active snapshot and exposes the rejected diagnostics.
- The default template in `DefaultConfig.swift` and `examples/vindu.toml` must be
  byte-identical. `make test` enforces this with `check-template`.
- The command and event sockets plus config watcher start before configuration is
  activated. They remain available in configuration-only mode.
- One daemon runs per user. The command socket is probed before bind: a live
  listener stops startup, while a dead socket file is removed.
- Private WindowServer symbols belong only to `VinduBorderEngine`, load from the
  fixed system framework path, and never appear as direct imports or a SkyLight
  link. A missing symbol or reported failure disables the border and logs once.
- WindowServer notification removal uses the same callback, event, and engine
  context as registration. The engine context and framework remain alive if
  removal fails.

## Configuration contract

- Vindu accepts TOML 1.1 with required `schema = 1`. Keys are case-sensitive.
  Unknown and duplicate keys, wrong types, non-finite values, invalid references,
  and values outside documented ranges reject the full candidate.
- The compiler has no aliases, ignored compatibility keys, variables, includes,
  inline mutation, unbind directive, comma-separated shorthand, or automatic
  converter.
- The default path is `~/.config/vindu/vindu.toml`. If neither native nor legacy
  config exists, Vindu atomically writes the canonical native template. If only
  `vindu.conf` exists, Vindu leaves it untouched and enters configuration-only
  mode with a diagnostic. An explicit `--config` path must exist and is never
  created.
- `vinductl config check` is offline and read-only. `config status` and
  `config reload` use the command socket. Saving the selected file also reloads
  through the watcher.
- An invalid startup candidate must not request Accessibility access or create
  window-management state. The first later valid candidate requests access once
  and starts the runtime when access is available.
- Configuration compatibility is intentionally not preserved. The established
  public dispatcher, information, JSON, and event wire contracts remain separate
  from the configuration schema.

## Platform constraints

- SIP stays on. Vindu cannot change another app's compositor content, so
  animations, blur, per-window opacity, rounded clipping of other apps' windows,
  and a click-to-kill picker remain unavailable. The active border is a separate
  Vindu-owned WindowServer surface.
- Workspace hiding is frame-stashing, not Space membership. Code that repositions
  windows must respect `hidden` and `nativeFullscreen`.
- The daemon uses Swift language mode 5 under tools 6.0 because its AX and event
  tap callbacks cross C APIs that strict Swift 6 concurrency cannot model well.
- The Accessibility grant is tied to code identity. Release and install builds
  are ad-hoc signed so equivalent rebuilds keep the grant; a new binary may need
  a re-toggle in System Settings.

## Testing and verification

- Portable behavior belongs in `VinduCore`; daemon support that does not need
  live AX/AppKit window access belongs in `VinduDaemonSupport`. Deterministic
  daemon boundary helpers can be tested through the `vindud` module without
  starting the daemon.
- Use `make test`, which supplies the Command Line Tools framework paths and also
  runs the border sanitizer harness and template check.
- The daemon re-tiles real windows. Live runtime verification requires explicit
  user consent and a logged-in macOS session.

## Conventions

- Configuration diagnostics identify the file and, when available, the TOML line
  and schema path. CLI and IPC failures use short, actionable text.
- Runtime IPC replies are `ok`, payload text or JSON, or `err: ...`; `vinductl`
  derives its exit status from that prefix.
- Commands use explicit execution intent: `run` is an argv array and `shell` is a
  `/bin/sh -lc` script. Environment additions are validated and cannot replace
  reserved `VINDU_*` values.
- The version string lives in `VinduVersion` and changes only for an explicit
  release decision.
