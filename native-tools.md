# Native tools: implementation decision

## Recommendation

Use PencilKit's marker, lasso and ruler rather than custom equivalents. The current drawing snapshots remain the authoritative storage; no raster layers, separate selection files or ruler geometry need to be added. Apple owns the live hit testing/rendering and serializes edited strokes through `PKDrawing`. This is the simplest candidate, not a measured claim that native tools use less battery than every custom renderer.

## Highlighter

`PKInkingTool(.marker, color: ..., width: ...)` provides native marker ink. It is the closest built-in highlighter: its stroke shape/compositing is Apple's marker behavior, not a promise of a custom constant-width rectangular translucent pen. The stroke carries its ink type/color/path in the existing archive. Increasing width/overlap can increase raster work and covered pixels; there is no required background worker, new network request or extra storage layer. Keep separate pen/marker width settings so enabling it does not change the pen's 1 pt startup default. Pen index `[1]` and dark Ink blue `#0033CC` initialize on every launch; live palette/width changes and saved tool restoration still work. Marker retains its independent 20 pt default.

## Selection

`PKLassoTool()` selects strokes in `PKCanvasView`. Moving or modifying selected ink changes the drawing and goes through our existing history/save path. Selection itself is transient UI state, not a new history node. iPadOS 27 additionally exposes `canvas.selection` (a set of stroke UUIDs) and `canvasViewSelectionDidChange`; this is not available at our iOS 26 deployment floor and needs an availability guard if used.

`DrawingCanvas` permits native editing interactions and restores only long presses that it previously suppressed while Selection is active. Leaving Selection ends editing and disables non-drawing long presses again; unrelated recognizers that were already disabled are not enabled. Native PencilKit menus perform deletion, not a custom stroke-editing layer.

On iPadOS 27, palette touch-down captures the selected UUIDs before native toolbar interaction can dismiss them; a completed color click recolors those strokes while retaining path, transform, mask, ink type, random seed and render state. Reusing a live stroke UUID left its rendered color unchanged in gesture tests, so recolored strokes receive fresh UUIDs and Selection is remapped to them. Document/page/history IDs and archive paths are unchanged. Recoloring is an ordinary undoable history edit; a same-color click creates none, including after archive restoration. The iOS 26 fallback keeps the earlier palette behavior.

A controller-owned keyboard-will-show observer ends editing in its window only while a drawing page is open in Selection. This prevents the keyboard and floating predictive strip without input-view, responder-eligibility or Scribble overrides. Home text entry is unaffected. Real simulator tests cover one-click recoloring on paper, fixed viewport, native movement/deletion, undo/redo, reopening and subsequent ink without resurrection. The source format remains PencilKit; `question` and `missed` tags are derived from exported native color during manual Sync, not inferred from opaque archive bytes on the server. Palette badges distinguish purple `?` and muddy-teal `…`; page ink stays ordinary native pen/marker with distinct colors, not a custom dashed or textured brush. Portable scene export and DGX previews are specified in [portable-sync.md](portable-sync.md).

## Ruler

`canvas.isRulerActive` enables Apple's native ruler directly; a visible `PKToolPicker` is not required. Ruler position/angle is transient UI. Ink drawn against it remains ordinary saved strokes. Moving the ruler does not invoke `canvasViewDidBeginUsingTool`, per Apple's SDK header. Native ruler manipulation may require finger gestures while Ruler is enabled, so the original 'fingers do nothing' rule needs that narrow exception. Disable it outside drawing pages and test it alongside palm protection/sidebars.

## Performance and storage boundaries

All three features use the existing PencilKit canvas, delegate callbacks and snapshot persistence. Manual Sync exports portable stroke scenes for DGX-generated PNGs; native PNG export remains available for legacy checks. A selection transform can affect many strokes in one operation; our whole-page snapshot cost already scales with page size. Marker overlap adds rendering work; ruler/selection UI adds work while active. Quantifying that requires later traces. Keep idle disabled tools free of custom redraw timers. Scene export and server image generation happen during manual Home Sync only, never per stroke.

## Sources

Verified against the installed Xcode 27 iOS SDK's public `PKCanvasView.h` and PencilKit Swift interface, plus Apple's documentation:

- [PKCanvasView](https://developer.apple.com/documentation/pencilkit/pkcanvasview)
- [PKInkingTool](https://developer.apple.com/documentation/pencilkit/pkinkingtool-swift.struct) (Swift type: `PKInkingTool`, native ink case `.marker`)
- [PKLassoTool](https://developer.apple.com/documentation/pencilkit/pklassotool-swift.struct)
- [Canvas ruler](https://developer.apple.com/documentation/pencilkit/pkcanvasview/isruleractive)

Implemented 2026-10-01 and updated 2026-10-06: all three toolbar buttons are enabled. Marker uses its own 8–60 pt width index (20 pt default), unaffected by the new pen-only minimum. As of 2026-10-07, one-contact quick eraser always returns to Pen after its contact, including when invoked from marker or lasso. It preserves the independent pen width and selected color; no persistent eraser mode remains. Ruler is transient, switches to the last ink tool when enabled from Selection, and is disabled on leaving a page. No source schema change, private PencilKit API or background task was added.
