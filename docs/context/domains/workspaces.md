# Workspaces

## Registry and id scheme

`WorkspaceRegistry` (VinduCore) owns the collection and Hyprland's id scheme: positive ids for regular workspaces, named workspaces allocated downward from −1337, specials downward from −99. Special-ness is a flag on the workspace, never derived from the id. Create/destroy hooks feed the IPC event stream.

Target resolution handles: absolute id, `±n` relative, `e±n` cyclic over existing positive ids, `previous`, `empty` (first id in 1…1000 with no windows), `name:` (allocating when creation is allowed), `special:`.

Dynamic lifecycle: a workspace that is empty, not visible, not special, and not bound by a workspace rule is destroyed. Garbage collection runs after switches, window moves, and closes.

## Visibility model

Per monitor, two slots: the active regular workspace and an optional special overlay. A special toggles over whatever is active; summoning it on one monitor removes it from any other. `binds:workspace_back_and_forth` makes re-selecting the current id bounce to the previous one. Each monitor remembers its previous workspace for `previous` targets and back-and-forth.

## Virtual workspaces (the SIP trick)

macOS exposes no per-Space window membership without disabling SIP, so invisible workspaces are simulated:

- Hide = stash each window as a 2-pixel sliver at its monitor's bottom-right corner (pinned and native-fullscreen windows are skipped).
- Show = re-arrange, which restores every frame, then focus the workspace's last-focused window.
- Pinned floating windows migrate into the incoming workspace on every switch.
- Daemon shutdown first restores all stashed windows to reachable positions.

## Multi-monitor

- Workspace ids 1…N are seeded onto monitors in order at startup; `workspace = N, monitor:Name` rules pin ids to displays.
- Switching to a workspace already visible on another monitor focuses that monitor instead of moving the workspace.
- `moveworkspacetomonitor` displaces the target monitor's visible workspace and backfills the old monitor: its previous workspace if still homed there, else the first id that is free or already homed on it.
- Monitor hotplug re-homes orphaned workspaces to the primary display and prunes per-monitor state.
- Monitor targets resolve by direction (shared neighbor scoring), index, `±n` cyclic, `current`, or name substring.
