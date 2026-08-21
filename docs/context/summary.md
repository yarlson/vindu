# vindu

Dynamic tiling window manager for macOS. One Swift package with one exact-pinned
TOML decoding dependency.

## What

- Tiles windows automatically with dwindle or master layouts, keyboard actions,
  workspaces, floating windows, fullscreen, and mouse-drag re-tiling.
- Uses a strict, versioned TOML configuration that compiles into one immutable
  runtime snapshot. The configuration has native Vindu concepts and no legacy
  aliases or compatibility parser.
- Uses the Accessibility API and a session event tap for window management. SIP
  stays on. `_AXUIElementGetWindow` maps AX elements to window ids; an optional
  internal border engine loads private WindowServer interfaces at runtime.
  Missing symbols and reported setup or runtime failures disable only the border.

## Architecture

Five targets keep platform work outside the portable model:

- `VinduCore` owns the strict configuration compiler, immutable configuration
  types, typed actions, layouts, workspace registry, rule matching, and public
  IPC models.
- `VinduDaemonSupport` owns configuration file selection and loading, the active
  configuration controller, sockets, file watching, LaunchAgent rendering, bar
  plugin execution, and weather fetches.
- `VinduBorderEngine` is the internal C boundary for the optional focus border.
  It dynamically loads private WindowServer symbols and owns one border surface.
- `vindud` owns AppKit, Accessibility, input, monitors, border coordination, the
  desktop bar, and runtime orchestration. AX events, input, config reloads, and
  IPC all reach `WindowManager` on the main queue.
- `vinductl` checks configuration files offline and acts as a thin socket client
  for a running daemon.

All window and border geometry uses top-left-origin global coordinates. AppKit's
flipped coordinates appear only at AppKit UI and cursor-position boundaries.

## Core flow

1. `DaemonCoordinator` starts the command and event sockets, loads one candidate,
   then arms the watcher before it activates that candidate.
2. `ConfigurationCompiler` decodes strict TOML and validates the full candidate.
   A valid candidate becomes an immutable `ConfigurationSnapshot`; a rejected
   reload leaves the active snapshot unchanged.
3. The daemon asks for Accessibility access and creates `WindowManager` only
   after a valid snapshot exists. An invalid first load leaves the daemon in
   configuration-only mode so `config status`, `config reload`, and file saves
   can repair it without restart.
4. `AXBridge` reports a window, which is classified as standard, dialog, or
   auxiliary. Ordered native rules produce its initial appearance and placement.
5. The window joins its workspace's master order and dwindle tree. Visible
   workspaces arrange; hidden workspaces stash windows just off-screen because
   macOS offers no Space control with SIP on.
6. Typed key bindings dispatch directly. The public command socket retains the
   established dispatcher and information protocol for external scripts.

## Capabilities

- Layouts: dwindle and master, switchable at runtime with window order preserved.
- Workspaces: numbered, named, special, per-monitor visibility, dynamic lifecycle,
  and display-name assignments that retry after monitor changes.
- Desktop bar: same-process AppKit bar with independent left, true-center, and
  right zones, built-in state items, weather, and bounded script plugins.
- Scripting: request/response command socket, JSON information replies, and a push
  event socket.
- Multi-monitor: directional focus and movement, workspace-to-monitor moves, and
  hotplug re-homing.
- Onboarding: menu bar controls, a keybinding sheet, and pause/resume.

## Tech stack

- Swift tools 6.0 in language mode 5, SwiftPM, macOS 13+, one internal C target.
- `TOMLDecoder` 0.4.5 at an exact revision, with no transitive dependencies.
- AppKit, ApplicationServices, and CGEvent taps in the daemon; CoreGraphics and
  a dynamically loaded WindowServer boundary in the border engine.
- GitHub Actions CI on a two-image macOS matrix; tag releases include universal
  binaries, provenance attestation, and a Homebrew formula update.

See [context-map.md](context-map.md) for the file index.
