# IPC and scripting

Two Unix sockets live in the per-user runtime dir (`XDG_RUNTIME_DIR` if set, else the per-user temp dir), under a `vindu/` subdirectory. `VinduPaths` (VinduCore) is the single source for these paths, shared by daemon and CLI.

## Command socket

Request/response, wire-compatible with Hyprland's socket1: one plain-text command per connection, one reply, close. A `j/` prefix (what `vinductl -j` sends) selects JSON. Replies are `ok`, payload text/JSON, or `err: …`.

- The accept loop reads on a background queue, runs the handler on the main queue (the WM is single-threaded), and writes the reply on a background queue.
- Startup probes an existing socket file: a live listener means another instance and the daemon exits; a dead file is stale and unlinked. This doubles as the single-instance mechanism.
- Verb families: `dispatch` (the full dispatcher set), `keyword`, `reload`, info verbs (`clients`, `workspaces`, `monitors`, `activewindow`, `activeworkspace`, `binds`, `getoption`, `configerrors`, `cursorpos`, `version`), plus `notify` and `splash`. Hyprland verbs with no macOS meaning return an explicit `err: … has no macOS equivalent`; `kill` (the click-to-close picker) is impossible and says so.

## JSON shapes

Info payloads mirror `hyprctl -j` shapes where macOS has an equivalent field (`ClientInfo`, `WorkspaceInfo`, `MonitorInfo`, `BindInfo`, `VersionInfo` in VinduCore). The window `address` is the hex CGWindowID. The client `fullscreen` field encodes 0 = none, 1 = maximize, 2 = fullscreen. Output is pretty-printed with sorted keys.

## Event socket

Push stream, wire-compatible with Hyprland's socket2: one `EVENT>>DATA` line per state change (workspace switches, focus, window open/close/move, floating changes, fullscreen, submaps, monitor add/remove, config reload). Clients are set non-blocking so one stalled consumer cannot wedge the daemon; clients whose writes fail are pruned. Status bars consume this stream instead of polling.

## vinductl

Thin client: joins its arguments into one request line, prints the reply, and exits 1 when the reply starts with `err` or `unknown`. `vinductl events` streams the event socket to stdout. The daemon ignores SIGPIPE so vanishing event clients cannot kill it.
