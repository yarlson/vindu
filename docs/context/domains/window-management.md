# Window management

## AX bridge

`AXBridge` owns one AX observer per regular-activation-policy app and translates accessibility notifications into delegate callbacks (appeared, destroyed, focused, moved/resized, title changed, minimized/deminimized). The CGWindowID comes from `_AXUIElementGetWindow` — private but long-stable, the standard approach for macOS tiling WMs.

Reliability measures, all load-bearing:

- AX destroy notifications are unreliable (destroyed elements lose CFEqual identity; some apps never send one), so a periodic reconcile pass reaps tracked windows absent from the window-server list on two consecutive passes.
- Apps register with the AX server asynchronously after launch, so window discovery retries on a short schedule after each app launch.
- `setFrame` runs position–size–position because apps clamp size against the current position, which lands off-target when crossing displays.

## Classification

Every AXWindow is classified before management:

- standard → tiles; dialog (including system dialogs and floating panels) → floats; auxiliary → never managed or focused.
- A window whose AXMain attribute is not settable is auxiliary (input-method candidate panels, picker HUDs, non-activating system surfaces).
- Unknown or missing subrole falls back to chrome heuristics: a title or close button means a real window; chromeless surfaces (autocomplete dropdowns, tooltips) stay invisible to the WM, and their focus events are swallowed so the parent window keeps focus and border.

## Per-window state

`WindowState` is daemon-side truth: `frame` is the desired tile frame for tiled windows and the live frame for floating ones; flags cover floating, pinned, minimized, hidden (stashed), nativeFullscreen, fakeFullscreen; `floatFrame` remembers floating geometry across tile/float toggles.

## Focus

- Focus the WM initiates and focus the OS reports share one bookkeeping path (focused window, workspace lastFocused, focused monitor, history, border, events).
- A new window is focused only when user-driven — its app is frontmost or nothing holds focus. Background spawns (input panels, updaters, slow launches the user tabbed away from) are managed, not focused. `workspace … silent` rules also skip focus.
- An OS focus event for a window on a hidden workspace switches there only if a user gesture (click or ⌘Tab) happened within the last few seconds, or `misc:focus_on_activate` is enabled; otherwise it is a focus steal and is ignored.
- Focus history (bounded) picks the next window after closes and minimizes; `focuscurrentorlast` uses it too.
- `input:follow_mouse = 1` focuses from throttled mouse-move samples — best effort, since focusing another app's window also activates the app and may raise it.

## Tiled frame enforcement

Tiled windows stick to their assigned tile: drift beyond a few pixels is re-asserted under a cooldown (prevents fight loops with apps that resist), and a debounced settle snaps the exact frame once the event burst quiets. Floating windows simply track the OS frame.

## Native fullscreen

The green button moves a window onto its own Space. Detection combines an AXFullScreen poll gated on already-fullscreen windows, monitor-sized event frames, and a rate-limited poll that catches app-internal animated transitions; an `activeSpaceDidChange` sweep covers transitions that deliver no AX move event at all. While native-fullscreen the window leaves the tiled structures; on exit it is re-adopted and re-arranged or stashed.

## Border overlay

A click-through, non-activating panel that joins all Spaces, framed around the focused window (coordinates convert to AppKit space at this boundary only). It renders the active-border gradient's first color, switches to the submap border color while a submap is active, and hides for hidden, minimized, or fullscreen windows.
