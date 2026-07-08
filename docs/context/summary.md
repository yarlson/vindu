# vindu

Dynamic tiling window manager for macOS. Single Swift package, zero external dependencies.

## What

- Tiles windows automatically (dwindle or master layout), keyboard-driven, with workspaces, floating, fullscreen, and mouse-drag re-tiling.
- Hyprland-compatible surface: same config dialect, dispatcher names, IPC verbs, and event wire format, so Linux configs and status-bar scripts largely work unchanged.
- Runs on the public Accessibility API plus a session event tap. SIP stays on. The only private symbol is `_AXUIElementGetWindow` (long-stable, used by every macOS tiling WM).

## Architecture

Four targets with a hard purity boundary:

- `VinduCore` — library holding all logic that can be pure: config language, settings, binds, dispatchers, window rules, both layout engines, workspace registry, IPC models and wire formats. No GUI dependencies; covered by `swift test`.
- `VinduDaemonSupport` — testable daemon infrastructure that does not need AX/AppKit window access: config file loading, IPC/socket helpers, config watching, LaunchAgent plist rendering, service log paths, desktop-bar plugin execution, and weather fetches.
- `vindud` — the daemon. Owns every OS integration: AX observers (`AXBridge`), the event tap (`HotkeyTap`), monitors, border overlay, AppKit desktop-bar panels, and launch orchestration. Single-threaded: AX events, hotkeys, and IPC all funnel into `WindowManager` on the main queue.
- `vinductl` — thin socket-client CLI.

All geometry is top-left-origin global coordinates; AppKit's flipped coordinates appear only at the border-overlay and cursor-position boundaries.

## Core Flow

1. `AXBridge` reports a window → classified standard / dialog / auxiliary (auxiliary surfaces are never managed).
2. Window rules fold into an initial placement (tile/float, workspace, size, pin, silent).
3. The window joins its workspace's dual layout structure (master order + dwindle tree, kept in lockstep).
4. Visible workspaces re-arrange: layout frames → gap math → border inset → AX setFrame. Hidden workspaces stash windows just off-screen instead (macOS offers no Space control with SIP on).
5. The event tap swallows bound chords and dispatches them; the command socket accepts the same dispatchers; every state change broadcasts on the event socket.

## System State

- Working WM distributed via Homebrew (`yarlson/tap/vindu`) and source builds, with launchd service self-install.
- VinduCore and VinduDaemonSupport behavior are unit-tested with swift-testing. Live `vindud` behavior still requires the Accessibility grant and a real window session.

## Capabilities

- Layouts: dwindle (aspect-based binary splits) and master (master area + stack), switchable at runtime with window order preserved.
- Workspaces: numbered, named, special (scratchpad overlays), per-monitor visibility, dynamic create/destroy, monitor-binding rules.
- Desktop bar: same-process AppKit bar, configured from `vindu.conf`, showing workspaces, focused app/window, built-in state indicators, and cached script-plugin items when enabled.
- Hyprland config compatibility with explicit tolerance lists; compositor-only options no-op cleanly.
- Scripting: hyprctl-style command socket (plain or JSON) and a push event socket.
- Multi-monitor: directional focus/movement across displays, workspace ↔ monitor moves, hotplug re-homing.
- Onboarding layer: menu bar status item, optional desktop bar, first-run keybinding cheat sheet, and a pause/resume escape hatch (`pause` dispatcher) — additive UX; the grid still owns tiled windows.

## Tech Stack

- Swift (tools 6.0, language mode 5 for C callback interop), SwiftPM, macOS 13+.
- AppKit + ApplicationServices (AX) + CGEvent taps, in the daemon only.
- GitHub Actions CI on a two-image macOS matrix; tag-driven releases with universal binaries, provenance attestation, and an automated Homebrew formula bump.

See [context-map.md](context-map.md) for the file index.
