# Bar plugin design

Status: accepted design proposal, not current implementation.

## Goal

Let users add ordered custom items to the desktop bar with small scripts, while
keeping rendering synchronous, predictable, and safe for the window-manager main
loop.

## V1 decision

Bar plugins are short-lived command plugins owned by `vindud`.

`DesktopBar` never runs shell commands while rendering. A daemon-side plugin
service runs configured commands asynchronously, caches their last valid output,
and asks the bar to re-render only when cached item state changes.

This keeps the bar model close to the existing weather indicator: slow work
happens off the render path, the UI consumes cached data, and failures do not
block layout or AppKit.

Plugin items are not clickable in v1. Status output and refresh control are the
first product surface; click actions can be added later without changing the
script output contract.

## Non-goals

- No in-process plugin ABI.
- No long-running supervised plugin processes.
- No JavaScript/Lua/runtime embedding.
- No per-monitor plugin instances in v1; plugin output is global and appears on
  each monitor where the item is configured.
- No plugin-defined custom views; plugins produce text plus optional SF Symbol
  and color metadata.
- No click actions in v1.

## Config shape

The existing `bar:indicators` list remains the ordering surface. Built-ins keep
their current names. Custom items use `plugin:<id>` tokens.

```conf
bar {
    indicators = weather,plugin:mail,network,battery,date

    plugin {
        mail {
            command = ~/.config/vindu/bar/mail.sh
            refresh_seconds = 300
            events = configreloaded,workspace,activewindow
            timeout_ms = 1000
        }
    }
}
```

Equivalent full keys:

- `bar:plugin:<id>:command`
- `bar:plugin:<id>:refresh_seconds`
- `bar:plugin:<id>:events`
- `bar:plugin:<id>:timeout_ms`

Rules:

- `<id>` must match `[A-Za-z0-9_-]+`.
- `command` is required when `plugin:<id>` is present in `bar:indicators`.
- `refresh_seconds` defaults to `60`; `0` disables interval refresh; otherwise
  valid range is `5...3600`.
- `timeout_ms` defaults to `1000`; valid range is `250...5000`.
- `events = none` disables event-triggered refreshes.
- Unknown plugin ids referenced from `bar:indicators` are config errors.

## Script execution

Commands run through `/bin/sh -lc`, matching the existing `exec` dispatcher
behavior and preserving shell-script ergonomics. The daemon starts each run in
its own process group, captures stdout and stderr, enforces the timeout with
TERM then KILL, and also cleans up background descendants after the shell exits.

One execution may be in flight per plugin. If another refresh is requested while
the command is running, the service records one pending refresh and runs it after
the current process exits.

Environment passed to scripts is intentionally minimal: `HOME`, `USER`,
`LOGNAME`, `SHELL`, `TMPDIR`, locale variables, a safe PATH, plus:

- `VINDU_BAR_PLUGIN_ID`
- `VINDU_BAR_PLUGIN_REASON` = `startup`, `interval`, `event`, or `manual`
- `VINDU_BAR_PLUGIN_EVENT` = event name for event-triggered runs
- `VINDU_BAR_PLUGIN_EVENT_DATA` = raw event payload for event-triggered runs
- `VINDU_COMMAND_SOCKET`
- `VINDU_EVENT_SOCKET`

Scripts can use `vinductl -j clients`, `vinductl events`, and other existing
IPC commands for richer state. The plugin runner does not invent a second query
API. `env = NAME,value` config entries are inherited by `exec` commands, not by
bar plugins; plugins that need credentials should read them from Keychain or
their own private files.

## Output contract

Stdout is capped at 8 KiB after UTF-8 decoding.

Plain text output is accepted:

```text
12
```

That renders as text only. Empty output hides the item.

JSON output is accepted when stdout starts with `{`:

```json
{
  "text": "12",
  "symbols": ["envelope.badge.fill", "envelope"],
  "color": "foreground",
  "visible": true
}
```

Fields:

- `text`: displayed text, trimmed to one line.
- `symbols`: optional SF Symbol fallback list.
- `color`: `foreground`, `inactive`, `active`, or any existing Vindu color
  literal such as `rgba(ffcc00ff)`.
- `visible`: optional bool; `false` hides the item.

Unknown JSON fields are ignored. Invalid JSON, invalid colors, and oversized
output are failures.

## Failure behavior

- If a plugin has a last valid value, failures keep rendering that value.
- If a plugin has no valid value yet, failures hide the item.
- Timeout, non-zero exit, invalid output, and missing command are logged with
  the plugin id/status.
- Stderr is never rendered in the bar and is not logged by default.
- Config reload cancels removed plugins and refreshes changed plugins.

## Event model

`WindowManager` already broadcasts `WMEvent` values to the public event socket.
The plugin service should receive the same internal events after broadcast and
refresh plugins whose `events` list contains the event name.

Supported v1 event names are the existing wire names:

- `workspace`
- `workspacev2`
- `focusedmon`
- `activewindow`
- `activewindowv2`
- `openwindow`
- `closewindow`
- `movewindow`
- `fullscreen`
- `changefloatingmode`
- `createworkspace`
- `destroyworkspace`
- `renameworkspace`
- `submap`
- `configreloaded`
- `monitoradded`
- `monitorremoved`
- `pause`

The event name and raw payload are exposed through environment variables. A
plugin that needs full state should query `vinductl`; event payload parsing
inside scripts should stay optional.

## Manual refresh API

Add one command-socket verb:

```sh
vinductl barplugin refresh mail
```

Reply rules:

- `ok` when a known plugin refresh was queued.
- `err: unknown bar plugin: <id>` for unknown ids.
- `err: bar plugin id required` for malformed commands.

This gives external scripts and launch agents a way to notify Vindu after an
external state change without keeping a persistent plugin process alive.

## Script examples

Text-only item:

```sh
#!/bin/sh
count="$(find "$HOME/Mail/Inbox" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "0" ] && exit 0
printf '%s\n' "$count"
```

Structured item:

```sh
#!/bin/sh
count="$(find "$HOME/Mail/Inbox" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "0" ] && printf '{"visible":false}\n' && exit 0
printf '{"text":"%s","symbols":["envelope.badge.fill","envelope"],"color":"foreground"}\n' "$count"
```

Event-aware item:

```sh
#!/bin/sh
case "$VINDU_BAR_PLUGIN_REASON:$VINDU_BAR_PLUGIN_EVENT" in
  event:activewindow|event:workspace|startup:|manual:)
    vinductl -j activewindow | jq -r '.class // empty'
    ;;
  *)
    exit 0
    ;;
esac
```

## Implementation shape

1. Model config in `VinduCore`.
   - Add `BarItem = builtin(BarIndicator) | plugin(String)`.
   - Change the ordered bar list from built-in-only indicators to mixed items.
   - Add `BarPluginConfig` and store plugin configs on `BarSettings`.
   - Keep built-in aliases unchanged.
   - Add parser tests for mixed order, plugin id validation, missing command,
     range validation, and `getoption`.

2. Add daemon plugin service.
   - New `DesktopBarPluginService` owns configs, timers, processes, cached
     `BarPluginValue`, and `onChange`.
   - It runs commands off the main queue and hops back to main before touching
     cached state.
   - It exposes `sync(configs:items:)`, `refresh(id:reason:)`, `handle(event:)`,
     and `stop()`.

3. Feed cached state into bar snapshots.
   - Extend `DesktopBarSystemInfo` or add a separate snapshot field for plugin
     values.
   - Render `plugin:<id>` items through the same `DesktopBarIndicatorView`
     presentation path as built-ins.

4. Wire events and IPC.
   - After broadcasting a `WMEvent`, notify the plugin service with the event
     name and payload.
   - Add the `barplugin refresh` IPC verb in `WindowManager+IPC`.

5. Document user-facing config.
   - Update `README.md`, `examples/vindu.conf`, `DefaultConfig.swift`, and
     `docs/context/*` only after implementation exists.

## Acceptance criteria

- A user can place `plugin:<id>` anywhere in `bar:indicators` and the bar
  preserves that order relative to built-ins.
- A shell script can render a text-only item or a structured item with SF Symbol
  fallbacks and color metadata.
- Scripts never run on the `DesktopBar` render path.
- Slow, failing, missing, or invalid scripts cannot block bar rendering or window
  management.
- Plugins can refresh on intervals, selected Vindu events, config reload, and
  explicit `vinductl barplugin refresh <id>`.
- Config errors identify unknown plugin ids, bad ids, missing commands, and
  invalid numeric ranges.
- Existing built-in indicators and aliases keep working.
- The implementation is covered by `VinduCore` parser/model tests plus focused
  daemon compile-time integration checks; no live `vindud` run is required.

## Deferred extension

Clickable plugin items should be designed separately if needed. A likely shape is
`on_click = dispatch ...` or `on_click = exec ...`, but that requires hit-target
routing in `DesktopBarIndicatorView`, click event semantics, and failure handling
for click commands. None of that is needed to make status plugins useful.
