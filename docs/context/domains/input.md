# Input

## Event tap

`HotkeyTap` creates a session CGEventTap (head-inserted, consuming) over keyboard, mouse buttons, drags, and mouse movement. Bound chords are swallowed before the frontmost app sees them — this is what lets ⌘-based binds shadow system shortcuts. The tap re-enables itself if the OS disables it (timeout or user input). All callbacks hop to the main queue.

While tiling is paused, only bindings whose typed action is `pause` match; every other chord, pointer binding, and raw-drag observation passes through untouched, so input belongs to apps until resume.

## Keyboard bindings

- Lookup uses the typed modifier set, keycode, edge, and active mode. Both down and up edges of a matched chord are swallowed so apps never see half a shortcut.
- `on = "release"` fires on release; `repeat = true` also fires on keyboard autorepeat and is invalid for a release binding.
- Configuration modifiers are `command`, `option`, `control`, and `shift`. The canonical template uses `option` because Command carries many common application shortcuts.
- Chord keys are lowercase names resolved through `KeyCodes`. Unknown names reject the configuration candidate.
- Each binding defines exactly one typed action. A reload replaces the full lookup table; if the active mode no longer exists, the tap returns to `default`.

## Mouse binds and drags

- Pointer bindings map `left`, `right`, or `middle` plus at least one configured modifier to a `move` or `resize` drag. Matched drags are fully swallowed.
- Unbound left-button activity is observed but never consumed, so native title-bar drags of tiled windows re-tile instead of fighting the layout.
- One `DragSession` model serves both sources. Native drags engage only after the window actually moves, so clicks and in-window drags (text selection) never re-tile. A size delta marks the session as a resize.
- Tiled move drag: the window follows the cursor while the rest of the workspace re-flows around it; entering another tile swaps live (with hysteresis on the last swap target). Dropping on another monitor joins that monitor's visible workspace, tiled.
- Tiled resize: a pointer resize binding feeds pixel deltas into the dwindle split ratios or the master primary fraction. A native edge resize adopts the final size intent into those values on release, then snaps every tile to the grid.
- Floating windows free-move and free-resize with a minimum size floor.
- Apply rates are throttled (drag frame application, raw drag callbacks, and follow-mouse samples each have their own small interval).

## User gestures and modes

- Clicks and ⌘Tab activity (each Tab press, and the ⌘ release that confirms the switcher) stamp a "user gesture" time; window activations shortly after one may switch workspaces, anything else is treated as an app-initiated focus steal.
- The active mode lives in the tap. The typed `enter_mode` action and retained runtime mode dispatcher set it, broadcast the mode event, and recolor the focus border.
