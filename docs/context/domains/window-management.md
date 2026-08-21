# Window management

## AX bridge

`AXBridge` owns one AX observer per regular-activation-policy app and translates accessibility notifications into delegate callbacks (appeared, destroyed, managed focus, actual focused surface, moved/resized, title changed, minimized/deminimized). The CGWindowID comes from `_AXUIElementGetWindow` — private but long-stable, the standard approach for macOS tiling WMs.

Reliability measures, all load-bearing:

- AX destroy notifications are unreliable (destroyed elements lose CFEqual identity; some apps never send one), so a periodic reconcile pass reaps tracked windows absent from the window-server list on two consecutive passes. Notification destruction, app detach, and reconcile all remove windows through the same path and clear the window's reconcile state.
- Apps register with the AX server asynchronously after launch, so window discovery retries on a short schedule after each app launch. A newly reported window whose geometry is temporarily invalid gets one bounded retry chain tied to the same live app, AX element, and window id.
- `setFrame` runs position–size–position because apps clamp size against the current position, which lands off-target when crossing displays.

AX frames must have finite, positive, integer-representable geometry. Invalid snapshots and move or resize updates are ignored, and invalid outgoing frames do not reach Accessibility. Layout arrangement validates every candidate before it changes window state, so one invalid frame leaves the whole workspace at its previous geometry. Floating move and resize dispatchers return an error instead of applying an invalid frame. IPC omits invalid client or monitor snapshots and reports an invalid cursor position instead of converting it to an integer.

## Classification

Every AXWindow is classified before management:

- standard → tiles; dialog (including system dialogs and floating panels) → floats; auxiliary → never managed.
- A window whose AXMain attribute is not settable is auxiliary (input-method candidate panels, picker HUDs, non-activating system surfaces).
- Unknown or missing subrole falls back to chrome heuristics: a title or close button means a real window; chromeless surfaces (autocomplete dropdowns, tooltips) stay invisible to window management. Their actual focus is still reported so the active border hides until focus returns to the managed parent.
- Border eligibility is narrower than management: only a standard window whose AX size is settable can receive the active border. Dialogs, sheets, progress windows, popups, and fixed-size windows do not.

## Per-window state

`WindowState` is daemon-side truth: `frame` is the desired tile frame for tiled windows and the live frame for floating ones; flags cover floating, pinned, minimized, hidden (stashed), nativeFullscreen, fakeFullscreen; `floatFrame` remembers floating geometry across tile/float toggles.

## Focus

- Focus the WM initiates and managed focus the OS reports share one bookkeeping path (focused window, workspace lastFocused, focused monitor, history, events). Actual system focus is tracked separately for active-border eligibility, including auxiliary surfaces that never enter `WindowState`.
- A new window is focused only when user-driven — its app is frontmost or nothing holds focus. Background spawns (input panels, updaters, slow launches the user tabbed away from) are managed, not focused. A non-silent `workspace …` rule follows the window to that workspace; `workspace … silent` moves it there without changing what the user sees.
- An OS focus event for a window on a hidden workspace switches there only if a user gesture (click or ⌘Tab) happened within the last few seconds, or `misc:focus_on_activate` is enabled; otherwise it is a focus steal and is ignored.
- Focus history (bounded) picks the next window after closes and minimizes; `focuscurrentorlast` uses it too.
- `input:follow_mouse = 1` focuses from throttled mouse-move samples — best effort, since focusing another app's window also activates the app and may raise it.

## Tiled frame enforcement

Tiled windows stick to their assigned tile: drift beyond a few pixels is re-asserted under a cooldown (prevents fight loops with apps that resist), and a debounced settle snaps the exact frame once the event burst quiets. If an app refuses the tile's full size, the accepted smaller frame is centered inside the assigned tile instead of being pinned to the tile origin. Floating windows simply track the OS frame.

## Native fullscreen

The green button moves a window onto its own Space. Detection combines an AXFullScreen poll gated on already-fullscreen windows, monitor-sized event frames, and a rate-limited poll that catches app-internal animated transitions; an `activeSpaceDidChange` sweep covers transitions that deliver no AX move event at all. While native-fullscreen the window leaves the tiled structures; on exit it is re-adopted and re-arranged or stashed.

## Active border

`WindowManager` selects at most one target: the actual focused surface must match the managed focused window, the window must be a resizable standard window, and it must be visible, unminimized, outside native and managed fullscreen, and not paused. `general:border_size <= 0` also hides it. Focus on a dialog, sheet, progress window, popup, or other auxiliary surface removes the border. Auxiliary focus leaves managed focus on the parent; managed dialogs remain floating and border-ineligible.

`BorderController` passes only the target id and current style to `VinduBorderEngine`. The engine owns one hollow, noninteractive WindowServer surface. It reads target bounds from WindowServer events, follows move and resize transactions, joins the target Space, copies its level and sublevel, and orders immediately below it. The full configured gradient is drawn. The target's reported corner radius is authoritative; `decoration:rounding` is the fallback when that capability is absent.

Every private symbol is resolved at runtime from the fixed SkyLight framework path. Notification registration and removal keep the engine context alive for the full callback lifetime. Invalid coordinates are never passed to WindowServer; the engine hides the border instead. Reported failures during normal operation disable only the border and emit one diagnostic. If notification removal fails during teardown, the engine and loaded framework remain retained so late callbacks still have valid context. A private ABI change that preserves the symbol names can still affect the in-process daemon, so each supported macOS version needs live validation. There is no AppKit border fallback, polling loop, external border process, or direct SkyLight link.

## Pause

The `pause` dispatcher (vindu extension, default `alt+shift+p`) suspends all enforcement: arrange/stash/tile-holding no-op, the border hides, focus events stop switching workspaces, and dispatchers other than `pause`/`exit`/`exec` return an error. Floating frames are still tracked so they stay where the user leaves them. Resume re-stashes hidden workspaces and re-arranges everything — the grid reasserts; pause is a timeout, not a mode.

## Menu bar and cheat sheet

A status item (hidden via `misc:menu_bar = false`) shows daemon presence, dims while paused, and offers pause/resume, the keybinding cheat sheet, opening the config file, and quit — the chord-free control surface. The cheat sheet is a click-to-dismiss overlay rendered from the live parsed binds (`BindDisplay` in VinduCore: macOS modifier symbols, plain-English actions, `bindd` descriptions when present, digit runs collapsed to `1…9`); it shows automatically on the run that writes the default config if it is not already visible, and large configs are clamped to the monitor with scrollable overflow.

## Desktop bar

`DesktopBar` is an optional same-process AppKit bar, enabled with `bar:enabled = true`. It creates one non-activating panel per monitor, joins all Spaces, and renders built-in workspace, focused-app/window, and configured state-indicator groups from `WindowManager` state rather than consuming the public IPC stream. Workspace items are normal AppKit buttons with accessibility labels and dispatch the workspace switch path for their monitor. Top bars draw at the physical display top so they can occupy the hidden-menu-bar strip; layout reserves only the part of the bar overlapping the monitor's usable frame. The focused app/window item sits next to the workspace switcher instead of in the center notch area and includes the focused/frontmost app icon when macOS exposes one. Fonts, spacing, padding, workspace-pill dimensions, app icons, and SF Symbol indicator icons scale from the resolved bar height. The right-side item sequence comes from `bar:indicators`; OS listeners and system polling are enabled only for configured built-ins, with keyboard/input-source, power, CoreWLAN/path network, and output volume/default-device/data-source changes invalidating the bar. Bar refreshes coalesce onto the next main-queue turn so paired focus/window events render once. A minute-aligned timer is enabled only when the date indicator is configured. Weather is opt-in, fetched asynchronously from Open-Meteo for `bar:weather_location`, cached, and refreshed on `bar:weather_refresh_minutes`; enabling it sends the configured coordinates to Open-Meteo. Weather response bodies stream into a 64 KiB buffer and the request stops as soon as it crosses that limit. Failed or invalid responses do not replace the cached value. Responses from canceled or superseded requests are ignored. Custom `plugin:<id>` items are daemon-run shell commands with cached output; scripts run off the render path in a short-lived process group, refresh on intervals, selected Vindu events, config changes, or `vinductl barplugin refresh <id>`, and render plain text or JSON-provided text/SF Symbols/color. One run per plugin is active at a time; refreshes requested during a run are coalesced into one pending rerun. A started run remains owned until its direct child has been reaped and its output pipes have been drained. Config changes request graceful group termination before a delayed forced kill. Daemon shutdown kills each active group and waits for reap and pipe drain before AppKit termination. Plugin processes receive a minimal environment: home/user/shell/temp/locale, a safe PATH, plugin id, refresh reason, triggering event, event payload, and both socket paths. They do not inherit config `env =` values or unrelated daemon file descriptors. Failed runs keep the last valid value visible; empty or hidden output removes the item until a later valid value. Stderr is drained but not logged by default. Network and volume render as icon-only when symbols are available but expose accessibility labels; volume switches from speaker to headphones when the current output looks like a headset/headphones route; date/time renders as text only.
