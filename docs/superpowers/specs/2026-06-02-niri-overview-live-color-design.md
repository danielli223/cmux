# niri overview: live color feed in tiles

**Date:** 2026-06-02
**Status:** Design — pending implementation
**Area:** niri strip mode overview (`StripWorkspaceView`, `StripCanvasView`, `WorkspaceStripController`, Ghostty portal)

## Problem

The niri overview (`⌃⌥V`, zoom-out) renders each column as a **monochrome text snapshot**
captured once when the overview opens (`ghostty_surface_read_text`, drawn as scaled monospace
text on a dark tile). It is colorless and frozen — it shows the text that existed at the instant
the overview opened, not what the terminal looks like now.

Goal: tiles should show a **live, full-color feed** of each column, updating while the overview
is open, for **every** column (on- and off-screen).

## Why it is not already done

Two constraints, documented in `docs/niri-mode.md`:

1. **Terminals reflow when shrunk.** Each terminal is a window-level `GhosttyMetalLayer`
   (`CAMetalLayer`) portal that renders *above* SwiftUI. cmux's portal sizes the surface to its
   host view's frame; shrinking that frame makes Ghostty **re-wrap** the grid (the "1-character
   sliver" bug family). So a column cannot simply be resized into a small tile.
2. **Off-screen columns stop rendering.** Opening the overview sets every column's
   `isVisibleInUI = false`, which calls `surfaceView.terminalSurface?.setOcclusion(false)` and
   `isHidden = true` (`GhosttySurfaceScrollView.setVisibleInUI`, `GhosttyTerminalView.swift`).
   Occluded surfaces stop producing frames, so there are no live pixels to show.

## Enabling facts (verified in source)

1. **The terminal layer's `contents` is an `IOSurfaceRef`.** The presented Metal drawable's
   surface is reachable as `layer.contents` (confirmed at `GhosttyTerminalView.swift:11213`,
   `CFGetTypeID(cf) == IOSurfaceGetTypeID()`). A separate `CALayer` can set its own `contents`
   to that same IOSurface and, with `contentsGravity = .resizeAspectFill`, **scale it down for
   free**. The source surface keeps rendering at full size — no reflow.
2. **A per-surface "new frame" signal already exists.** `GhosttyMetalLayer.nextDrawable()` calls
   `surfaceView.enqueueRenderedFrameUpdate()`, which posts `.ghosttyDidRenderFrame` (object =
   the `GhosttyNSView`) — but only while demand is held via
   `GhosttyNSView.retainRenderedFrameNotifications()` (a refcount, `GhosttyRenderedFrameNotificationDemand`).
   This is a ready-made "mirror needs refresh" trigger.

## Chosen approach: IOSurface mirror — live for on-screen columns, frozen for the rest

(Decisions confirmed with the user: **live color for the columns that are currently rendering
(on-screen); a frozen snapshot for the rest**, and **throttle mirror refresh to ~10–15 fps** to
bound GPU/CPU cost. This is deliberately the scope-reduced variant — we do **not** force
off-screen columns to keep rendering, which removes the hard risk.)

A column is "on-screen" when its terminal portal is actively rendering — i.e. it was visible in
the viewport immediately before the overview opened. Off-screen columns were already occluded and
not producing frames before the overview; we leave them that way.

While the overview is open:

1. **Keep the already-rendering (on-screen) columns rendering at full size**, but visually
   suppressed so their live portals do not bleed over the overview backdrop. Off-screen columns
   stay occluded — no change to their rendering. Concretely: instead of today's blanket
   `isVisibleInUI = false` for *every* column on overview open, only the previously-off-screen
   columns are occluded; the previously-visible ones are switched to "render-but-suppressed."
2. **On-screen tiles are live layer-backed mirror views.** Each tile's `layer.contents` is set to
   the source surface layer's current `IOSurfaceRef`, `contentsGravity = .resizeAspectFill`,
   `masksToBounds = true`. The source full-size frame is mirrored, shrunk to the tile rect — no
   reflow because the source is never resized.
3. **Off-screen tiles are frozen.** When the overview opens, capture a one-time **color snapshot**
   of each on-screen surface's current IOSurface (a retained `CGImage` / detached IOSurface copy)
   as a baseline; off-screen columns that have no recent frame fall back to the existing **text
   snapshot**. Frozen tiles never refresh while the overview is open.
4. **Refresh is event-driven but throttled (live tiles only).** Hold one rendered-frame-
   notification retain token for the whole overview session. On `.ghosttyDidRenderFrame` for a
   live-mirrored surface, mark that tile dirty; a single coalescing timer (~10–15 fps, one tunable
   constant) re-reads the dirty surfaces' current IOSurface and assigns it to the corresponding
   mirror layers. This bounds the blit rate regardless of terminal output rate.

### Rejected alternative

**Whole-strip `CATransform3D` scale.** Zoom the live strip via a layer transform instead of
mirroring. Rejected: the portal re-reads host frames on geometry change and would reflow — the
exact sliver-bug family the AppKit canvas hosting (`StripCanvasViewController`) was built to
avoid. Low confidence; not pursued.

## Components

- **`OverviewMirrorLayer` (new).** A layer-backed `NSView` (or bare `CALayer` wrapper) that owns
  the mirror layer for one window. API: `attachLive(sourceSurfaceLayer:)`, `refresh()` (re-read
  source IOSurface → assign to own `contents`), `showFrozen(image:)` / `showFallback(text:)`.
  Lives in its own file per the one-type-per-file rule.
- **`StripWorkspaceView.overviewTile` (changed).** Replaces the `windowMiniScreen` text `Text`
  with an `OverviewMirrorLayer`-hosting view per window; keeps the title bar, tab indicator,
  selection border, and tap-to-select chrome unchanged. Live mirror when the source is rendering,
  frozen color snapshot otherwise, text snapshot when no frame is available.
- **`WorkspaceStripController` (changed).** Owns overview-session lifecycle: on
  `enterOverview()` acquire the rendered-frame retain token, mark previously-visible columns
  render-but-suppressed (leaving off-screen columns occluded), and capture frozen baselines; on
  `cancelOverview()` / `selectOverviewColumn()` release the token and restore normal
  `isVisibleInUI` gating. Owns the throttle timer and the source-surface → mirror routing. Keeps
  `overviewThumbnails` (text) as the deepest fallback.
- **`StripCanvasView` / `StripCanvasViewController` (changed).** The overview visibility gate
  changes from "every column off (occluded, not rendering)" to "previously-visible columns
  render-but-suppressed; previously-off-screen columns occluded as before."

## Data flow

```
enterOverview()
  → retain rendered-frame notifications (1 token, whole session)
  → previously-visible columns: render-but-suppressed (un-occluded, not bleeding over overview)
  → previously-off-screen columns: stay occluded (unchanged)
  → capture frozen baselines: color snapshot per surface with a recent IOSurface; text otherwise
per frame (Ghostty present, live columns only):
  GhosttyMetalLayer.nextDrawable() → enqueueRenderedFrameUpdate() → .ghosttyDidRenderFrame
  → controller marks mirror for that surface dirty
throttle timer (~10–15 fps):
  → for each dirty live mirror: mirror.layer.contents = sourceLayer.contents (IOSurface); clear
cancel/select overview:
  → release token; restore isVisibleInUI gating; tear down mirrors + timer
```

## Spike (first implementation step — confirms the suppression mechanism)

The hard "force off-screen columns to render" risk is **out of scope** (off-screen tiles are
frozen). The remaining, smaller question: when a *previously-visible* column is kept un-occluded
but visually suppressed so it does not bleed over the overview, does it keep producing frames?

**Test:** with the overview open, take a previously-visible column, keep `setOcclusion(true)`
while suppressing its visual contribution, and confirm (a) `.ghosttyDidRenderFrame` keeps firing
and (b) its `layer.contents` IOSurface seed (`IOSurfaceGetSeed`) advances when content changes
(e.g. a running `seq`/clock).

**Outcome decides suppression mechanism:**
- If hidden-in-place still renders → suppress via `isHidden`/zero-alpha on the host while keeping
  occlusion on. Cheapest.
- If hidden layers stall → park the host full-size **off-screen** (outside viewport bounds, like
  the existing fullscreen "parked column" trick at `StripCanvasView.swift:232`) so the window
  server still composites it, and mirror from there.

If even on-screen columns will not render while suppressed, degrade gracefully: capture a frozen
color snapshot of every column at overview-open (no live tiles) and flag it to the user. This is
strictly better than today's monochrome text and keeps the feature shippable.

## Cost

Bounded by design: only the handful of previously-visible columns render live, and their mirror
blits are **capped by the ~10–15 fps throttle** rather than terminal output rate. Off-screen
columns add zero rendering cost (frozen). The throttle interval is a single named constant.

## Testing

Behavioral, per the test-quality policy — no source-text assertions.

- **Throttle/coalescing logic** (pure, unit-testable): given a burst of frame-dirty events and a
  clock, the refresh coalescer fires at most once per interval and always reflects the latest
  dirty set. Extract this into a small pure type (like `CmuxStripLayout`) so it tests without a
  GPU.
- **Session lifecycle** (`WorkspaceStripController`): entering the overview acquires exactly one
  rendered-frame retain token, marks previously-visible columns render-but-suppressed, and leaves
  previously-off-screen columns occluded; canceling/selecting releases the token and restores
  `isVisibleInUI`. Assert via a test seam (token count, per-column desired-visibility state) —
  observable model state, not view internals.
- **Tile-mode selection**: given a column's render/snapshot state, the selection function returns
  *live* for a currently-rendering source, *frozen color* for one with a captured baseline image,
  and *text* when neither is available. Test the selection function, not the pixels.
- **Spike** is a manual/dogfood verification (frame counter + IOSurface seed), not a CI test.

UI/pixel correctness (does the tile actually show color) is a manual review item, consistent with
how the existing overview's "scale transition smoothness" is treated.

## Out of scope

- Interacting with a live tile (typing into the zoomed-out feed). Tiles stay click-to-select.
- Changing the hold-to-preview / commit / cancel interaction model.
- Browser-panel columns (the overview is terminal-column oriented today).
