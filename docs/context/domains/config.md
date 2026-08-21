# Config

One file: `vindu.conf` under the XDG-style config dir (default `~/.config/vindu/`). When missing, the embedded default template is written on first run. Saves apply live; `vinductl keyword` applies single assignments without touching the file.

## Language

Hyprland dialect, parsed by `ConfigParser` (VinduCore):

- `key = value` assignments; `section { … }` blocks nest into colon-joined keywords (`general:gaps_in`).
- `$variables`, substituted longest-name-first so `$mainModShift` survives `$mainMod`.
- `source = path` includes (tilde and relative-to-including-file resolution; nesting capped at 10, with total sourced file and byte caps).
- `#` comments; `##` escapes a literal `#`; a line starting with `#` is wholly a comment.
- `submap = name` … `submap = reset` delimit modal bind blocks.

## Document model

Parsing produces a `ConfigDocument`: settings, binds, window rules, workspace rules, exec/exec-once lists, env entries, recorded `monitor =` lines, and errors. Notable semantics:

- `env = NAME,value` entries are applied to the daemon environment and inherited by `exec` children. Desktop-bar plugins do not inherit these values; they receive only a minimal allowlisted environment plus `VINDU_BAR_PLUGIN_*` context and socket paths.
- `vindu.conf` is plaintext trusted configuration, not a secret store; scripts that need credentials should read them from Keychain or their own private files.
- `monitor =` lines are recorded but never applied — macOS owns display arrangement.
- `workspace = N, monitor:Name` pins a workspace id to a monitor (case-insensitive substring match).
- `unbind` removes matching binds parsed so far.
- Errors carry line numbers; parsing always completes and never throws.

## Settings

`Settings` is a typed option table keyed by full keyword; each entry implements both `set` (with validation and ranges) and `get` (serves IPC `getoption`). Modeled sections: general, decoration (rounding only), dwindle, master, input, misc, binds, bar. Bar plugin options validate both when parsed from the file and when applied live: a `plugin:<id>` item in `bar:indicators` needs a configured command before the config is considered clean.

`general:border_size` is the active-border width; zero disables the border. `general:col.active_border` and `general:col.submap_border` keep every configured color stop and angle. `decoration:rounding` is used only when the WindowServer cannot report the target's corner radius. `general:col.inactive_border` remains a compatibility no-op because vindu draws no inactive borders.

The `bar` section is a vindu extension for the same-process desktop bar:

- `bar:enabled` turns it on/off (off by default so existing installs keep the same screen geometry).
- `bar:position` is `top` or `bottom`; `bar:height` is 0…96 px. `0` means automatic: top bars use the display's top reserved strip (matching the hidden macOS menu-bar height), while other cases fall back to 28 px.
- `bar:show_workspaces`, `bar:show_app`, and `bar:show_indicators` toggle the built-in item groups.
- `bar:indicators` is a comma-separated ordered list for the right-side group. Allowed built-ins are `pause`, `submap`, `layout`, `windows`, `date`, `battery`, `network`, `keyboard`, `volume`, and `weather`; `none` clears the list. Aliases such as `paused`, `mode`, `clock`, `wifi`, `keyboard_layout`, `sound`, `audio`, `temperature`, and `temp` are accepted. Custom script items use `plugin:<id>`.
- `bar:weather_location` is `latitude,longitude` for the Open-Meteo-backed weather indicator; empty or `none` disables weather fetches. Enabling it sends those configured coordinates to Open-Meteo on refresh. `bar:weather_refresh_minutes` controls the refresh interval, 5…180 minutes, default 15.
- `bar:plugin:<id>:command` configures a custom script item referenced by `plugin:<id>` in `bar:indicators`; ids allow letters, digits, `_`, and `-`. `bar:plugin:<id>:refresh_seconds` defaults to 60 (`0` disables interval refresh, otherwise 5…3600), `bar:plugin:<id>:events` is a comma-separated list of Vindu event names or `none`, and `bar:plugin:<id>:timeout_ms` defaults to 1000 (250…5000). Script stdout is capped, must be UTF-8, and may be plain text or JSON with `text`, `symbols`, `color`, and `visible`. Plugin stderr is drained so scripts cannot block, but it is not logged by default.
- `bar:col.background`, `bar:col.foreground`, `bar:col.inactive`, and `bar:col.active` use the same color notation as border colors.

Tolerance tiers for real Hyprland configs:

1. Whole sections with no macOS counterpart (animations, gestures, …) accept any key silently.
2. A fixed list of known Hyprland keys inside modeled sections is accepted silently.
3. Everything else is an error — typos in modeled sections stay visible.

## Live updates and reload

- The IPC `keyword` verb routes through the same assignment path as the parser, so even `bind`/`unbind` work live; the hotkey tap rebuilds and visible workspaces re-arrange.
- `ConfigWatcher` watches the file with a dispatch source and a debounce, re-arming after delete/rename events because editors save atomically; if the file is briefly absent it retries on a short timer.
- A missing config on startup writes the embedded default atomically. An existing unreadable or non-UTF8 config aborts startup instead of silently using defaults.
- A file reload reruns `exec` lines but not `exec-once`; config errors trigger a notification pointing at `configerrors`.
- If the file cannot be read during reload, the last good config remains active and `configerrors` gets a line-0 load error. Binds, layout, and environment are not rebuilt from defaults on read failure.
