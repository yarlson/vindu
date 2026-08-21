# Workspaces

## Registry and id scheme

`WorkspaceRegistry` in VinduCore owns the collection: positive ids for regular workspaces, named workspaces allocated downward from -1337, and special workspaces downward from -99. Special status is a field on the workspace, never inferred from the id. Create and destroy hooks feed the IPC event stream.

Target resolution handles: absolute id, `±n` relative, `e±n` cyclic over existing positive ids, `previous`, `empty` (first id in 1…1000 with no windows), `name:` (allocating when creation is allowed), `special:`.

Relative targets use the full signed integer id range without trapping. A result below workspace 1 resolves to 1, a positive overflow does not resolve, and cyclic existing-workspace targets reduce any offset before applying it.

Dynamic lifecycle: a workspace that is empty, not visible, not special, and not bound by a workspace rule is destroyed. Garbage collection runs after switches, window moves, and closes.

## Visibility model

Per monitor, two slots: the active regular workspace and an optional special overlay. A special toggles over whatever is active; summoning it on one monitor removes it from any other. `workspaces.back_and_forth` makes re-selecting the current id bounce to the previous one. Each monitor remembers its previous workspace for `previous` targets and back-and-forth.

## Virtual workspaces (the SIP trick)

macOS exposes no per-Space window membership without disabling SIP, so invisible workspaces are simulated:

- Hide = stash each window as a 2-pixel sliver at its monitor's bottom-right corner (pinned and native-fullscreen windows are skipped).
- Show = re-arrange, which restores every frame, then focus the workspace's last-focused window.
- Pinned floating windows migrate into the incoming workspace on every switch.
- Daemon shutdown first restores all stashed windows to reachable positions, stops owned services once, waits for active bar-plugin processes to be killed, reaped, and drained, and asks AppKit to terminate on the next main-queue turn.

## Multi-monitor

- Workspace ids 1...N are seeded onto monitors in order at startup. `[[workspaces.assignments]]` entries assign ids to display names.
- Assignment matching tries case-insensitive exact names first, then a unique case-insensitive substring. A missing or ambiguous display leaves the workspace in place, records a runtime warning, and is retried after monitor changes.
- Switching to a workspace already visible on another monitor focuses that monitor instead of moving the workspace.
- `moveworkspacetomonitor` displaces the target monitor's visible workspace and backfills the old monitor: its previous workspace if still homed there, else the first id that is free or already homed on it.
- Monitor hotplug re-homes orphaned workspaces to the primary display and prunes per-monitor state.
- Monitor targets resolve by direction (shared neighbor scoring), index, `±n` cyclic, `current`, or name substring.
