# Layout engines

Every workspace maintains all layout models; `layout.kind` picks which one produces frames. Window order survives switching: master order is canonical, and the other models rebuild from it. Leaving scrolling flattens its columns into master order and discards grouping. Entering scrolling creates one column per window.

## Dwindle

Binary split tree (`DwindleTree`):

- A new window splits the focused leaf (fallback: the last leaf); split orientation follows the target leaf's aspect ratio (wider than tall → horizontal).
- `layout.dwindle.new_window_position` selects whether a new window enters before or after the target leaf. `new_window_fraction` sets its direct share from 0.1 through 0.9.
- `togglesplit` transposes the split above a window; `swapsplit` swaps its children; `splitratio` adjusts it (delta or exact).
- Pixel resize walks ancestors to the nearest split on the matching axis and converts the delta into a ratio change against that split's cached rect.
- Every node caches its last computed rect; removal promotes the sibling into the parent's slot.

## Master

`MasterLayout` is an ordered window list where the first `masterCount` windows are primary and the rest form the stack. Typed configuration actions and the retained runtime dispatchers can focus or swap the primary window, change the primary count and fraction, rotate position, and cycle or swap order.

- Primary-fraction and position runtime overrides fall back to `layout.master.primary_fraction` and `primary_position`. Those overrides survive config reloads.
- Five orientations: left/right/top/bottom/center; center alternates the stack onto both sides of a centered master area.
- `layout.master.new_window_position` accepts `primary`, `stack-start`, or `stack-end`.

## Scrolling

`ScrollingLayout` owns ordered horizontal columns, vertical stacks inside each column, preserved column widths, remembered focus per column, and a horizontal viewport. `layout.scrolling.default_column_width` is a fraction greater than zero and at most one; it defaults to one half.

- A tiled window opens as a new column after the focused column. A background window does not change focus or the viewport.
- Left and right focus move between columns and restore each column's remembered window. Up and down move within a stack. Focus reveals only the hidden part of a column; a column wider than the viewport aligns to the left.
- Horizontal move actions reorder columns. Vertical move actions reorder windows in a stack. Swap actions exchange the directional windows.
- Column actions consume the remembered window from the next column, expel the focused window into a new right-hand column, cycle one-third/one-half/two-thirds widths, toggle full width with restore, or center the column. The same actions are available as `vinductl dispatch column <action>`.
- Fully off-viewport windows are parked at the display edge while their logical frames remain unchanged. Keyboard viewport changes animate for 150 ms with cubic ease-out. Trackpad movement uses native deltas and momentum without custom inertia.
- Special workspaces always use dwindle. With more than one display, scrolling requires macOS Displays have separate Spaces. Vindu uses dwindle and reports a runtime warning until that setting or the display count makes scrolling safe again.

## Geometry

`LayoutMath` is pure and shared:

- Gap semantics: a tile side flush with the container edge gets `gaps_out`; sides facing other tiles get `gaps_in`. Adjacent tiles both contribute, so the visual inner gap is 2 × gaps_in.
- `stackRects` splits an area into equal tiles along one axis.
- Directional neighbor scoring: nearest candidate whose center lies beyond the source center in the given direction, with perpendicular offset penalized 2×. The same scoring serves focus movement, tile swaps, and monitor adjacency.

## Arrange pipeline

`WindowManager.arrange` runs per visible workspace: engine frames → gap application → inset by focus-border width → fullscreen-frame override → `WindowGeometryController`. Floating windows use their remembered `floatFrame` (default: centered, 60% × 70% of the container). Scrolling motion sizes once, coalesces position-only frames, and performs one final readback reconciliation. When `ui.bar.enabled` is true, any part of the desktop bar that overlaps the monitor's usable area is reserved before layout frames are computed. A top bar is drawn at the physical display top, so with the macOS menu bar hidden it occupies that normally excluded strip instead of adding a second gap. Special workspaces use a container inset 8% from that same usable area and raise their windows above the workspace beneath. Minimized and native-fullscreen windows are skipped; a window being dragged can be excluded so the rest re-flows around it.
