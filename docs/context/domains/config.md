# Configuration

Vindu uses one strict TOML 1.1 file. The default path is
`~/.config/vindu/vindu.toml`; `vindud --config <path>` selects an explicit file.
Every file starts with `schema = 1`.

## Selection and startup

- If the default native file exists, it wins even when `vindu.conf` also exists.
- If neither file exists, Vindu creates the config directory and atomically writes
  the canonical native template.
- If only `vindu.conf` exists, Vindu does not read, convert, rename, or delete it.
  The daemon enters configuration-only mode and reports where to create the TOML
  file.
- An explicit path resolves relative to the caller, must exist, and is never
  created or replaced by Vindu.

The command and event sockets start before the first load. The watcher is armed
before the candidate is activated and keeps retrying when the selected path does
not exist. An invalid first candidate does not trigger the Accessibility prompt
or create a window manager. A later valid save or `config reload` activates the
snapshot and requests Accessibility access once. If access was already granted,
the runtime starts at once.

## Compiler

`ConfigurationCompiler` in `VinduCore` owns the pipeline:

1. Reject files larger than 1 MiB or bytes that are not UTF-8.
2. Decode TOML with the exact-pinned `TOMLDecoder` package.
3. Reject unknown keys through the schema key validator. TOML decoding rejects
   duplicate keys, invalid syntax, and wrong value types.
4. Compile schema values into domain types and validate ranges, names, references,
   action cardinality, regular expressions, commands, colors, and cross-field
   constraints.
5. Return one immutable `ConfigurationSnapshot` or ordered diagnostics.

Keys are case-sensitive snake_case. There are no aliases, tolerated keys,
variables, includes, CSV fields, unbind directives, source directives, inline
mutation commands, converter, or fallback parser. A rejected candidate never
partly changes runtime state.

## Snapshot sections

- `layout`: kind, inner and outer gaps, dwindle new-window fraction and position,
  and master primary fraction, position, and new-window position.
- `focus`: pointer-following and whether off-workspace app activation may switch
  the visible workspace.
- `workspaces`: back-and-forth switching and display assignments.
- `ui.menu_bar`: menu bar visibility.
- `ui.focus_border`: width, fallback corner radius, active gradient colors and
  angle, and mode colors.
- `ui.bar`: enabled state, top or bottom placement, height, three item zones,
  colors, optional weather coordinates, and script plugins.
- `keyboard`: typed keyboard bindings and pointer drags.
- `startup`: ordered commands run when the window-management runtime starts.
- `windows`: ordered appearance-time rules.

See `examples/vindu.toml` for the complete canonical form and defaults.

## Typed commands and actions

A keyboard binding defines one chord, optional mode, press or release edge,
repeat behavior, and exactly one action. Modes must exist in the same candidate.
Pointer bindings need at least one modifier and map a button to move or resize.

`run = ["/absolute/program", "arg"]` executes an argv array without shell
parsing. The executable must be absolute or start with `~/`. `shell = "..."`
executes through `/bin/sh -lc`. Both forms can add an `env` table of validated
string values; reserved `VINDU_*` names cannot be replaced.

## Desktop bar

`ui.bar.left`, `center`, and `right` are independent ordered arrays. Left and
right stay on their physical edges. Center stays at the physical display center,
not the remaining space center. If it would overlap either side or the notch,
Vindu hides the whole center zone instead of shifting it. Items cannot repeat
across zones.

Built-ins are `workspaces`, `application`, `pause`, `mode`, `layout`, `windows`,
`date`, `battery`, `network`, `keyboard`, `volume`, and `weather`. Weather needs
validated coordinates and sends them to Open-Meteo when refreshed.

Custom items use `plugin:<id>` and a matching `ui.bar.plugins.<id>` table. A
plugin chooses either `run` or `shell`, plus optional environment, interval,
event names, and timeout. The runner bounds output and time, owns one active
process per plugin, drains both pipes, terminates the process group on timeout or
shutdown, and caches the last valid value. Plugin processes receive a small
allowlisted environment plus their own configured additions.

## Workspace assignments and window rules

Each workspace assignment has a positive id and monitor name. Monitor matching
tries case-insensitive exact equality first, then a unique case-insensitive
substring. Missing and ambiguous matches become runtime warnings, leave the
workspace in its current home, and retry after monitor changes.

Window rules run in order only when a window appears. `bundle_id` matches exactly;
`app_name` and `title` are validated regular expressions. Rules can set floating,
centered, pinned, fullscreen, size, position, workspace, and monitor. Later rules
replace earlier values field by field. Reloading does not reapply rules to
existing windows.

## Reload and diagnostics

The file watcher follows atomic editor saves and debounces reloads. A successful
reload swaps the full snapshot on the main queue, rebuilds the input map, updates
layout and UI policy, reconciles display assignments, restarts affected plugins,
and broadcasts `configreloaded`. Layout runtime overrides survive a config reload.

A failed reload keeps the active snapshot. `vinductl config status` reports the
selected path, daemon state, active schema, latest attempt, rejected diagnostics,
and runtime warnings. `vinductl config reload` requests a load and reports success
or failure. `vinductl config check [path]` compiles a file offline, never contacts
the daemon, and never creates or changes files.
