# Herdr Menubar Status Icon Design

**Date:** 2026-08-29

## Goal

Simplify the macOS menu-bar indicator by removing the overlaid status dot. Attention remains visible through the existing numeric count, while connection availability remains visible through icon opacity.

## Behavior

| Runtime state | Menu-bar presentation |
| --- | --- |
| Connected, no agents need attention | Opaque terminal icon; no numeric title. |
| Connected, one or more agents need attention | Opaque terminal icon followed by the aggregate attention count. |
| Searching, connecting, or no Herdr sessions | Dimmed terminal icon; no numeric title. |

The indicator remains a monochrome template image so macOS supplies the appropriate light or dark menu-bar color. No red, yellow, or other custom colors are introduced.

## Implementation

`MenuBarIconPresentation` will retain its existing state-derived mode, opacity, attention count, and `showsAttentionCount` properties. The `LightStyle` state is no longer needed because it only exists to select the removed dot rendering.

Both renderers must display the same dot-free icon:

- `MenuBarIcon` removes the SwiftUI overlay and renders only the `terminal` SF Symbol.
- `NativeStatusItemIconRenderer` removes the light-style field from its rendered content and stops drawing the circle into the AppKit image. It continues to use a template `NSImage`, the existing terminal symbol size, the title count, and the opacity supplied by the presentation.

Accessibility labels, accessibility values, tooltip text, title font, title behavior, connection-state logic, and attention-count aggregation remain unchanged.

## Tests

Update `MenuBarIconTests` to assert state mode, opacity, count, and count visibility without a light-style expectation. Update native status-item renderer tests to verify that rendering content no longer contains status-light data while retaining the expected title and opacity for connected, attention, and unavailable states.

Run the focused icon/status-item tests, then the complete `HerdrMenubarTests` unit suite. Rebuild and reinstall through `./scripts/install.sh` only after the tests pass.

## Non-goals

- Changing the terminal SF Symbol.
- Adding colors or custom menu-bar appearance behavior.
- Changing status semantics, attention aggregation, notifications, shortcuts, or menu content.
