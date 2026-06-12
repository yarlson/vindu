# Layout engines

Every workspace maintains both engines at all times; `general:layout` picks which one produces frames. Window order survives switching: master order is canonical, and the dwindle tree is rebuilt from it, replaying insertion with frame recomputation so aspect-based splits behave as if windows arrived one by one.

## Dwindle

Binary split tree (`DwindleTree`), Hyprland semantics:

- A new window splits the focused leaf (fallback: the last leaf); split orientation follows the target leaf's aspect ratio (wider than tall → horizontal).
- `dwindle:force_split` overrides which side the new window takes; `dwindle:default_split_ratio` seeds the ratio.
- Ratios use Hyprland's 0.1–1.9 scale (1.0 = even split) at the surface, stored halved internally and clamped to 0.1–0.9.
- `togglesplit` transposes the split above a window; `swapsplit` swaps its children; `splitratio` adjusts it (delta or exact).
- Pixel resize walks ancestors to the nearest split on the matching axis and converts the delta into a ratio change against that split's cached rect.
- Every node caches its last computed rect; removal promotes the sibling into the parent's slot.

## Master

`MasterLayout`: an ordered window list where the first `masterCount` windows are masters and the rest are the stack. Controlled via `layoutmsg` (swapwithmaster, focusmaster, addmaster/removemaster, mfact, orientation commands, cycle/swap next/prev).

- mfact and orientation have runtime overrides that fall back to the `master:*` settings.
- Five orientations: left/right/top/bottom/center; center alternates the stack onto both sides of a centered master area.
- `master:new_status` ("master"/"slave") and `master:new_on_top` control where new windows enter.

## Geometry

`LayoutMath` is pure and shared:

- Gap semantics: a tile side flush with the container edge gets `gaps_out`; sides facing other tiles get `gaps_in`. Adjacent tiles both contribute, so the visual inner gap is 2 × gaps_in.
- `stackRects` splits an area into equal tiles along one axis.
- Directional neighbor scoring: nearest candidate whose center lies beyond the source center in the given direction, with perpendicular offset penalized 2×. The same scoring serves focus movement, tile swaps, and monitor adjacency.

## Arrange pipeline

`WindowManager.arrange` runs per visible workspace: engine frames → gap application → inset by border width → fullscreen-frame override → `AXBridge.setFrame`. Floating windows use their remembered `floatFrame` (default: centered, 60% × 70% of the container). When `bar:enabled` is true, any part of the desktop bar that overlaps the monitor's usable area is reserved before layout frames are computed. A top bar is drawn at the physical display top, so with the macOS menu bar hidden it occupies that normally excluded strip instead of adding a second gap. Special workspaces use a container inset 8% from that same usable area and raise their windows above the workspace beneath. Minimized and native-fullscreen windows are skipped; a window being dragged can be excluded so the rest re-flows around it.
