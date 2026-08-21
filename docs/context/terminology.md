# Terminology

- configuration candidate — all bytes read from one selected TOML file before
  activation. It either compiles as a whole or is rejected as a whole.
- configuration snapshot — immutable, validated runtime configuration owned by
  `WindowManager`. A reload swaps the full snapshot in one main-queue operation.
- configuration-only mode — control sockets and the config watcher are active,
  but Vindu has no valid snapshot, does not request Accessibility access, and
  does not manage windows.
- action — one typed operation in a keyboard binding, such as focus, workspace,
  fullscreen, command, or enter mode.
- mode — a named modal keyboard map. `default` is the root map. Entering a mode
  also changes the focus-border color.
- workspace target — selector syntax used by typed actions: an id, a signed
  relative offset such as `+1` or `-1`, `previous` for the last visited
  workspace, `empty`, `name:<name>`, or `special:<name>`.
- monitor target — a direction, index, relative index, `current`, or monitor name.
- special workspace — scratchpad overlaid on the active workspace and rendered in
  an inset container. Its ids allocate downward from -99.
- named workspace — workspace addressed by name. Its ids allocate downward from
  -1337.
- dwindle — binary split-tree layout. Each new window splits the focused leaf and
  the leaf shape selects the split axis.
- master — primary area plus stack layout, controlled by typed primary actions and
  the established runtime dispatcher surface.
- primary fraction — share of the workspace used by the master layout's primary
  area.
- master order — canonical per-workspace window order, kept in sync with the
  dwindle tree so layouts can switch at runtime.
- floating — window outside the tiled structures with remembered `floatFrame`.
- pinned — floating window that migrates to the workspace visible on its monitor.
- stashed — window parked as a 2-pixel sliver because its workspace is hidden.
- native fullscreen — macOS green-button fullscreen. The window leaves the layout
  while it occupies its own Space.
- fullscreen — Vindu-managed display coverage. Maximize is the separate usable-
  area mode.
- window rule — appearance-time matcher and field overrides. Rules fold in file
  order and later configured fields win.
- auxiliary window — chromeless AX surface such as a tooltip or input-method
  panel. It is never managed or focused by Vindu.
- address — public IPC window identity: the CGWindowID rendered in hexadecimal.
- command socket — same-user request/response Unix socket for runtime actions,
  information, configuration status, and reload.
- event socket — same-user push stream of `EVENT>>DATA` lines.
- user gesture — recent explicit click or application switch used to distinguish
  a wanted off-workspace activation from focus stealing.
- pause — action that stops tiling enforcement until resumed while leaving the
  control surfaces available.
- desktop bar — optional same-process AppKit bar with independent left, centered,
  and right item zones.
- bar plugin — bounded script item addressed as `plugin:<id>`; the daemon runs it
  off the render path and caches parsed output.
- keybinding sheet — click-to-dismiss view built from the active typed keyboard
  bindings and available from the menu bar.
