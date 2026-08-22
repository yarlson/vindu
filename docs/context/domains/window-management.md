# Window management

## AX bridge

`AXBridge` owns one AX observer per regular-activation-policy app and translates accessibility notifications into delegate callbacks (appeared, destroyed, managed focus, actual focused surface, moved/resized, title changed, minimized/deminimized). The CGWindowID comes from `_AXUIElementGetWindow` — private but long-stable, the standard approach for macOS tiling WMs.

Reliability measures, all load-bearing:

- AX destroy notifications are unreliable (destroyed elements lose CFEqual identity; some apps never send one), so a periodic reconcile pass reaps tracked windows absent from the window-server list on two consecutive passes. Notification destruction, app detach, and reconcile all remove windows through the same path and clear the window's reconcile state.
- Apps register with the AX server asynchronously after launch, so window discovery retries on a short schedule after each app launch. A newly reported window whose geometry is temporarily invalid gets one bounded retry chain tied to the same live app, AX element, and window id.
- `setFrame` runs position–size–position because apps clamp size against the current position, which lands off-target when crossing displays.

AX frame coordinates must be finite and integer-representable; width and height must also be positive. Invalid snapshots and move or resize updates are ignored, and invalid outgoing frames do not reach Accessibility. Layout arrangement validates every candidate before it changes window state, so one invalid frame leaves the whole workspace at its previous geometry. Floating move and resize dispatchers return an error instead of applying an invalid frame. IPC omits invalid client or monitor snapshots and reports an invalid cursor position instead of converting it to an integer.

## Classification

Every AXWindow is classified before management:

- normal-level resizable standard windows tile by default; standard windows above the normal WindowServer level, fixed-size standard windows, and dialogs (including system dialogs and floating panels) float by default; auxiliary windows are never managed.
- A window whose AXMain attribute is not settable is auxiliary (input-method candidate panels, picker HUDs, non-activating system surfaces).
- Unknown or missing subrole falls back to chrome heuristics: a title or close button means a real window; chromeless surfaces (autocomplete dropdowns, tooltips) stay invisible to window management. Their actual focus is still reported so the active border hides until focus returns to the managed parent.
- A failed AX size-capability query leaves a normal-level standard window tiled by default but border-ineligible. Missing WindowServer level information preserves the role and resize-capability default. Window rules can override each managed window's default placement.
- Border eligibility is narrower than management: only a standard window whose AX size is known to be settable can receive the active border. Dialogs, sheets, progress windows, popups, fixed-size windows, and windows with an unknown resize capability do not.

## Per-window state

`WindowState` is daemon-side truth: `frame` is the desired tile frame for tiled windows and the live frame for floating ones; flags cover floating, pinned, minimized, hidden (stashed), nativeFullscreen, fakeFullscreen; `floatFrame` remembers floating geometry across tile/float toggles.

## Focus

- Focus the WM initiates and managed focus the OS reports share one bookkeeping path (focused window, workspace lastFocused, focused monitor, history, events). Actual system focus is tracked separately for active-border eligibility, including auxiliary surfaces that never enter `WindowState`.
- A new window is focused only when user-driven: its app is frontmost or nothing holds focus. Background spawns are managed but not focused. An appearance rule can select a workspace or monitor for the new window without changing existing windows on reload.
- An OS focus event for a window on a hidden workspace switches there only if a user gesture happened within the last few seconds, or `focus.allow_app_activation` is true; otherwise it is a focus steal and is ignored.
- Focus history (bounded) picks the next window after closes and minimizes; `focuscurrentorlast` uses it too.
- `focus.follows_pointer = true` focuses from throttled mouse-move samples. This is best effort because focusing another app's window also activates that app and may raise it.

## Tiled frame enforcement

Tiled windows stick to their assigned tile: drift beyond a few pixels is re-asserted under a cooldown (prevents fight loops with apps that resist), and a debounced settle snaps the exact frame once the event burst quiets. If an app refuses the tile's full size, the accepted smaller frame is centered inside the assigned tile instead of being pinned to the tile origin. Floating windows simply track the OS frame.

## Native fullscreen

The green button moves a window onto its own Space. Detection combines an AXFullScreen poll gated on already-fullscreen windows, monitor-sized event frames, and a rate-limited poll that catches app-internal animated transitions; an `activeSpaceDidChange` sweep covers transitions that deliver no AX move event at all. While native-fullscreen the window leaves the tiled structures; on exit it is re-adopted and re-arranged or stashed.

## Active border

`WindowManager` selects at most one target: the actual focused surface must match the managed focused window, the window must be a resizable standard window, and it must be visible, unminimized, outside native and managed fullscreen, and not paused. `ui.focus_border.width = 0` also hides it. Focus on a dialog, sheet, progress window, popup, or other auxiliary surface removes the border. Auxiliary focus leaves managed focus on the parent; managed dialogs remain floating and border-ineligible.

`BorderController` passes only the target id and current style to `VinduBorderEngine`. The engine owns one hollow, noninteractive WindowServer surface. It reads target bounds from WindowServer events, follows move and resize transactions, joins the target Space, copies its level and sublevel, and orders immediately below it. The full configured gradient is drawn. The target's reported corner radius is authoritative; `ui.focus_border.fallback_corner_radius` is used when that capability is absent.

Every private symbol is resolved at runtime from the fixed SkyLight framework path. Notification registration and removal keep the engine context alive for the full callback lifetime. Invalid coordinates are never passed to WindowServer; the engine hides the border instead. Reported failures during normal operation disable only the border and emit one diagnostic. If notification removal fails during teardown, the engine and loaded framework remain retained so late callbacks still have valid context. A private ABI change that preserves the symbol names can still affect the in-process daemon, so each supported macOS version needs live validation. There is no AppKit border fallback, polling loop, external border process, or direct SkyLight link.

## Pause

The pause action (default `option+shift+p`) suspends all enforcement: arrangement, stashing, and tile holding stop; the border hides; focus events stop switching workspaces; and runtime dispatchers other than pause, exit, and command execution return an error. Floating frames are still tracked so they stay where the user leaves them. Resume re-stashes hidden workspaces and re-arranges everything. Pause is a timeout, not a keyboard mode.

## Menu bar and cheat sheet

A status item (hidden with `ui.menu_bar.enabled = false`) shows daemon presence, dims while paused, and offers pause or resume, the keybinding sheet, opening the selected config file, and quit. The sheet is a click-to-dismiss view rendered from the active typed bindings through `BindDisplay` in VinduCore. It uses macOS modifier symbols and plain action labels; digit runs collapse to `1...9`. It appears automatically after Vindu writes the first native config, and large configurations scroll inside the monitor bounds.

## Desktop bar

`DesktopBar` is an optional same-process AppKit bar, enabled with `ui.bar.enabled = true`. It creates one non-activating panel per monitor, joins all Spaces, and renders `ui.bar.left`, `center`, and `right` from `WindowManager` state rather than consuming public IPC. Side zones stay at their physical edges. The center zone stays at the display center even when the sides have different widths; it is hidden as a unit if it would collide with a side or notch.

Workspace items are AppKit buttons with accessibility labels and dispatch the switch path for their monitor. Top bars draw at the physical display top so they can occupy the hidden-menu-bar strip; layout reserves only the overlap with the monitor's usable frame. Fonts, spacing, padding, workspace pills, app icons, and SF Symbol icons scale from the resolved bar height.

OS listeners and polling run only for built-ins present in any zone. Bar refreshes coalesce onto the next main-queue turn, and the date timer aligns to minutes. Optional weather uses configured coordinates with Open-Meteo, a 64 KiB response cap, cancellation, and a last-valid-value cache.

Custom `plugin:<id>` items run outside rendering through either direct argv or explicit shell commands. Runs use a short-lived process group, bounded output and timeout, one active process per plugin, and one coalesced pending rerun. Reconfiguration terminates replaced groups; shutdown waits for the child to be reaped and both pipes to drain. Plugins receive an allowlisted base environment, socket and event context, plus only their configured environment additions. Failed runs keep the last valid value; empty or hidden output removes the item until a later valid value. Stderr is drained but not logged by default.
