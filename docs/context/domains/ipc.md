# IPC and scripting

Two Unix sockets live in the per-user runtime dir (`XDG_RUNTIME_DIR` if set, else the per-user temp dir), under a `vindu/` subdirectory. `VinduPaths` (VinduCore) is the single source for these paths, shared by daemon and CLI. The directory must be owned by the current user and private (`0700`); unsafe directories, symlinks, non-socket socket paths, and non-owned paths fail closed.

## Command socket

Request/response, wire-compatible with Hyprland's socket1: one plain-text command per connection, one reply, close. A `j/` prefix (what `vinductl -j` sends) selects JSON. Replies are `ok`, payload text/JSON, or `err: …`.

- Accepted peers must have the same UID (`getpeereid`). This prevents cross-user control; same-user processes are trusted by design.
- The accept loop uses nonblocking per-client dispatch sources with an idle timeout, request-size cap, active-client cap, and full reply writes. The handler runs on the queue passed by `vindud`, which is the main queue because the WM is single-threaded.
- Startup probes an existing socket file: a live listener means another instance and the daemon exits; a dead Unix socket is stale and unlinked. Regular files, directories, symlinks, and non-owned paths are not unlinked.
- Verb families: `dispatch` (the full dispatcher set), `keyword`, `reload`, info verbs (`clients`, `workspaces`, `monitors`, `activewindow`, `activeworkspace`, `binds`, `getoption`, `configerrors`, `cursorpos`, `version`), plus `barplugin refresh <id>`, `notify`, and `splash`. Hyprland verbs with no macOS meaning return an explicit `err: … has no macOS equivalent`; `kill` (the click-to-close picker) is impossible and says so.
- While tiling is paused, `dispatch` rejects everything except `pause`, `exit`, and `exec` with an error pointing at the resume path.

## JSON shapes

Info payloads mirror `hyprctl -j` shapes where macOS has an equivalent field (`ClientInfo`, `WorkspaceInfo`, `MonitorInfo`, `BindInfo`, `VersionInfo` in VinduCore). The window `address` is the hex CGWindowID. The client `fullscreen` field encodes 0 = none, 1 = maximize, 2 = fullscreen. Output is pretty-printed with sorted keys.

## Event socket

Push stream, wire-compatible with Hyprland's socket2: one `EVENT>>DATA` line per state change (workspace switches, focus, window open/close/move, floating changes, fullscreen, submaps, monitor add/remove, config reload, plus the vindu-only `pause>>0|1`). Event clients must also be same-UID. Payload CR/LF characters are replaced before writing the line protocol so app-controlled titles cannot forge extra event lines; JSON/info APIs keep exact values. Clients are nonblocking and are pruned on failed, partial, or would-block writes, so slow consumers may miss events and should reconnect.

## vinductl

Thin client: joins its arguments into one request line, prints the reply, and exits 1 when the reply starts with `err` or `unknown`. `vinductl events` streams the event socket to stdout. The daemon ignores SIGPIPE so vanishing event clients cannot kill it.
