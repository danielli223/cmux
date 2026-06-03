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

## Chosen approach: IOSurface mirror, all columns, throttled refresh

(Decisions confirmed with the user: **live color for all columns**, **throttle mirror refresh to
~10–15 fps** to bound GPU/CPU cost.)

While the overview is open:

1. **Keep every column's surface rendering at full size**, but visually suppressed so the live
   portals do not bleed over the overview backdrop. This replaces today's blanket
   `isVisibleInUI = false` for the duration of the overview. The exact suppression mechanism —
   *hidden in place* vs *parked fully off-screen* — is decided by the spike below.
2. **Each overview tile is a layer-backed mirror view.** Its `layer.contents` is set to the
   source surface layer's current `IOSurfaceRef`, `contentsGravity = .resizeAspectFill`,
   `masksToBounds = true`. The source full-size frame is mirrored, shrunk to the tile rect.
3. **Refresh is event-driven but throttled.** Hold one rendered-frame-notification retain token
   for the whole overview session. On `.ghosttyDidRenderFrame` for a mirrored surface, mark that
   tile dirty; a single coalescing timer (~10–15 fps, one tunable constant) re-reads the dirty
   surfaces' current IOSurface and assigns it to the corresponding mirror layers. This bounds the
   blit rate regardless of how fast terminals emit frames.
4. **Fallback for not-yet-rendered surfaces.** A surface that has not produced a frame since the
   overview opened (or whose IOSurface is unavailable) shows the existing text snapshot. The
   text-snapshot capture path is retained as the fallback, not removed.

### Rejected alternative

**Whole-strip `CATransform3D` scale.** Zoom the live strip via a layer transform instead of
mirroring. Rejected: the portal re-reads host frames on geometry change and would reflow — the
exact sliver-bug family the AppKit canvas hosting (`StripCanvasViewController`) was built to
avoid. Low confidence; not pursued.

## Components

- **`OverviewMirrorLayer` (new).** A layer-backed `NSView` (or bare `CALayer` wrapper) that owns
  the mirror layer for one window. API: `attach(sourceSurfaceLayer:)`, `refresh()` (re-read
  source IOSurface → assign to own `contents`), `showFallback(text:)`. Lives in its own file per
  the one-type-per-file rule.
- **`StripWorkspaceView.overviewTile` (changed).** Replaces the `windowMiniScreen` text `Text`
  with an `OverviewMirrorLayer`-hosting view per window; keeps the title bar, tab indicator,
  selection border, and tap-to-select chrome unchanged. Falls back to text when no live frame.
- **`WorkspaceStripController` (changed).** Owns overview-session lifecycle: on
  `enterOverview()` acquire the rendered-frame retain token and switch columns into
  "render-but-suppressed" mode; on `cancelOverview()` / `selectOverviewColumn()` release the
  token and restore normal `isVisibleInUI` gating. Owns the throttle timer and the
  source-surface → mirror routing. Keeps `overviewThumbnails` (text) as the fallback source.
- **`StripCanvasView` / `StripCanvasViewController` (changed).** The visibility gate for the
  overview changes from "off (occluded, not rendering)" to "rendering, visually suppressed."
  This is the riskiest edit and is gated by the spike.

## Data flow

```
enterOverview()
  → retain rendered-frame notifications (1 token, whole session)
  → columns: render-but-suppressed (un-occluded, not bleeding over overview)
  → capture text snapshots (fallback)
per frame (Ghostty present):
  GhosttyMetalLayer.nextDrawable() → enqueueRenderedFrameUpdate() → .ghosttyDidRenderFrame
  → controller marks mirror for that surface dirty
throttle timer (~10–15 fps):
  → for each dirty mirror: mirror.layer.contents = sourceLayer.contents (IOSurface); clear dirty
cancel/select overview:
  → release token; restore isVisibleInUI gating; tear down mirrors + timer
```

## Spike (first implementation step — resolves the only hard risk)

**Question:** does a column whose host view is *hidden / parked off-screen* but **un-occluded**
keep producing Metal frames?

**Test:** with the overview open, take one off-screen column, keep `setOcclusion(true)` while
suppressing its visual contribution, and confirm (a) `.ghosttyDidRenderFrame` keeps firing for
it and (b) its `layer.contents` IOSurface seed (`IOSurfaceGetSeed`) advances when its content
changes (e.g. a running `seq`/clock).

**Outcome decides suppression mechanism:**
- If hidden-in-place still renders → suppress via `isHidden`/zero-alpha on the host while keeping
  occlusion on. Cheapest.
- If hidden layers stall → park the host full-size **off-screen** (outside viewport bounds, like
  the existing fullscreen "parked column" trick at `StripCanvasView.swift:232`) so the window
  server still composites it, and mirror from there.

If neither keeps off-screen columns rendering, fall back to: live mirror for on-screen columns,
frozen color snapshot (first captured IOSurface) for the rest — and flag the scope reduction to
the user before proceeding.

## Cost

Per open-overview frame: N full-size surface renders + up to N IOSurface assignments, **capped by
the ~10–15 fps throttle** rather than terminal output rate. The throttle interval is a single
named constant. If profiling shows trouble at high column counts, the throttle can be lowered or
combined with the "visible-tiles-only" strategy without touching the model.

## Testing

Behavioral, per the test-quality policy — no source-text assertions.

- **Throttle/coalescing logic** (pure, unit-testable): given a burst of frame-dirty events and a
  clock, the refresh coalescer fires at most once per interval and always reflects the latest
  dirty set. Extract this into a small pure type (like `CmuxStripLayout`) so it tests without a
  GPU.
- **Session lifecycle** (`WorkspaceStripController`): entering the overview acquires exactly one
  rendered-frame retain token and switches columns to render-but-suppressed; canceling/selecting
  releases the token and restores `isVisibleInUI`. Assert via a test seam (token count, per-column
  desired-visibility state) — observable model state, not view internals.
- **Fallback selection**: a surface with no captured frame yields the text fallback; one with a
  live IOSurface yields the mirror. Test the selection function, not the pixels.
- **Spike** is a manual/dogfood verification (frame counter + IOSurface seed), not a CI test.

UI/pixel correctness (does the tile actually show color) is a manual review item, consistent with
how the existing overview's "scale transition smoothness" is treated.

## Out of scope

- Interacting with a live tile (typing into the zoomed-out feed). Tiles stay click-to-select.
- Changing the hold-to-preview / commit / cancel interaction model.
- Browser-panel columns (the overview is terminal-column oriented today).
