# Config

One file: `vindu.conf` under the XDG-style config dir (default `~/.config/vindu/`). When missing, the embedded default template is written on first run. Saves apply live; `vinductl keyword` applies single assignments without touching the file.

## Language

Hyprland dialect, parsed by `ConfigParser` (VinduCore):

- `key = value` assignments; `section { … }` blocks nest into colon-joined keywords (`general:gaps_in`).
- `$variables`, substituted longest-name-first so `$mainModShift` survives `$mainMod`.
- `source = path` includes (tilde and relative-to-including-file resolution; nesting capped at 10).
- `#` comments; `##` escapes a literal `#`; a line starting with `#` is wholly a comment.
- `submap = name` … `submap = reset` delimit modal bind blocks.

## Document model

Parsing produces a `ConfigDocument`: settings, binds, window rules, workspace rules, exec/exec-once lists, env entries, recorded `monitor =` lines, and errors. Notable semantics:

- `env = NAME,value` entries are applied to the daemon environment and inherited by `exec` children.
- `monitor =` lines are recorded but never applied — macOS owns display arrangement.
- `workspace = N, monitor:Name` pins a workspace id to a monitor (case-insensitive substring match).
- `unbind` removes matching binds parsed so far.
- Errors carry line numbers; parsing always completes and never throws.

## Settings

`Settings` is a typed option table keyed by full keyword; each entry implements both `set` (with validation and ranges) and `get` (serves IPC `getoption`). Modeled sections: general, decoration (rounding only), dwindle, master, input, misc, binds, bar.

The `bar` section is a vindu extension for the same-process desktop bar:

- `bar:enabled` turns it on/off (off by default so existing installs keep the same screen geometry).
- `bar:position` is `top` or `bottom`; `bar:height` is 0…96 px. `0` means automatic: top bars use the display's top reserved strip (matching the hidden macOS menu-bar height), while other cases fall back to 28 px.
- `bar:show_workspaces`, `bar:show_app`, and `bar:show_indicators` toggle the built-in item groups.
- `bar:col.background`, `bar:col.foreground`, `bar:col.inactive`, and `bar:col.active` use the same color notation as border colors.

Tolerance tiers for real Hyprland configs:

1. Whole sections with no macOS counterpart (animations, gestures, …) accept any key silently.
2. A fixed list of known Hyprland keys inside modeled sections is accepted silently.
3. Everything else is an error — typos in modeled sections stay visible.

## Live updates and reload

- The IPC `keyword` verb routes through the same assignment path as the parser, so even `bind`/`unbind` work live; the hotkey tap rebuilds and visible workspaces re-arrange.
- `ConfigWatcher` watches the file with a dispatch source and a debounce, re-arming after delete/rename events because editors save atomically; if the file is briefly absent it retries on a short timer.
- A file reload reruns `exec` lines but not `exec-once`; config errors trigger a notification pointing at `configerrors`.
