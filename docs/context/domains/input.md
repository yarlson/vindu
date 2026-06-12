# Input

## Event tap

`HotkeyTap` creates a session CGEventTap (head-inserted, consuming) over keyboard, mouse buttons, drags, and mouse movement. Bound chords are swallowed before the frontmost app sees them — this is what lets ⌘-based binds shadow system shortcuts. The tap re-enables itself if the OS disables it (timeout or user input). All callbacks hop to the main queue.

While tiling is paused, only `pause` binds match; every other chord, mouse bind, and raw-drag observation passes through untouched, so the keyboard belongs to the apps again until resume.

## Key binds

- Lookup key is modifier mask + keycode + active submap. Both down and up edges of a bound chord are swallowed so apps never see half a shortcut.
- `binde` also fires on autorepeat; `bindr` fires on release instead of press.
- SUPER maps to ⌘ and ALT to ⌥; alt is the default mod because cmd carries too much existing muscle memory.
- Key names resolve through `KeyCodes`; `code:NN` passes raw keycodes; unknown names are config errors at parse time.

## Mouse binds and drags

- `bindm` chords (evdev button codes `mouse:272/273/274`) start drag sessions and are fully swallowed; a `bindm` with no modifiers is never matched.
- Unbound left-button activity is observed but never consumed, so native title-bar drags of tiled windows re-tile instead of fighting the layout.
- One `DragSession` model serves both sources. Native drags engage only after the window actually moves, so clicks and in-window drags (text selection) never re-tile. A size delta marks the session as a resize.
- Tiled move drag: the window follows the cursor while the rest of the workspace re-flows around it; entering another tile swaps live (with hysteresis on the last swap target). Dropping on another monitor joins that monitor's visible workspace, tiled.
- Tiled resize: a `bindm` resize drag feeds pixel deltas into split ratios (dwindle) or mfact (master); a native edge-resize adopts the final size intent into the ratios on release, then snaps everything to the grid.
- Floating windows free-move and free-resize with a minimum size floor.
- Apply rates are throttled (drag frame application, raw drag callbacks, and follow-mouse samples each have their own small interval).

## User gestures and submaps

- Clicks and ⌘Tab activity (each Tab press, and the ⌘ release that commits the switcher) stamp a "user gesture" time; window activations shortly after one may switch workspaces, anything else is treated as an app-initiated focus steal.
- The active submap lives in the tap. The `submap` dispatcher sets it, broadcasts the event, and recolors the focus border so the mode is visible.
