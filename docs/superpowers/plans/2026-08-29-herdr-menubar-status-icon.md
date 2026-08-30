# Herdr Menubar Status Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the status-light dot from the native Herdr menubar icon while preserving the terminal icon, attention count, dimmed unavailable state, and accessible status text.

**Architecture:** Keep `MenuBarIconPresentation` as the single state-to-presentation mapping for attention count, count visibility, mode, and opacity. Remove its dot-specific light-style state, then have both the SwiftUI preview renderer and the production AppKit status-item renderer use only the terminal SF Symbol. The status item remains a monochrome template image and still applies count text and opacity separately.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Xcode 26/macOS 26.

**Design spec:** `docs/superpowers/specs/2026-08-29-herdr-menubar-status-icon-design.md`

## Global Constraints

- Use a monochrome template image; do not introduce red, yellow, or other custom menu-bar colors.
- Show an attention count only for a connected state with `attentionCount > 0`.
- Use a dimmed terminal icon with no count for searching, connecting, and no-session states.
- Preserve existing accessibility labels, accessibility values, tooltip text, title font, and attention aggregation.
- Do not change the terminal SF Symbol, menu content, notifications, shortcuts, or connection semantics.

---

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/Menu/MenuBarIcon.swift` | Shared presentation state and the SwiftUI terminal icon preview. |
| `HerdrMenubar/Menu/StatusItemController.swift` | Production AppKit template-image construction and application to the status-item button. |
| `HerdrMenubarTests/MenuBarIconTests.swift` | State-to-presentation and accessibility behavior. |
| `HerdrMenubarTests/StatusItemControllerTests.swift` | Native status-item count, opacity, template, and icon geometry behavior. |

## Shared commands

Focused menu-icon tests:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/MenuBarIconTests
```

Focused status-item tests:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/StatusItemControllerTests
```

Full non-UI suite:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

---

### Task 1: Add a failing native dot-free icon geometry test

**Files:**

- Modify: `HerdrMenubarTests/StatusItemControllerTests.swift:303-324`

**Interfaces:**

- Consumes: `NativeStatusItemIconRenderer.apply(_:accessibilityValue:to:)` and `MenuBarIconPresentation(connectionState:attentionCount:)`.
- Produces: a regression test requiring the rendered terminal image to occupy its natural 18-by-18 point canvas rather than the old 20-by-18 canvas that reserved space for the status dot.

- [ ] **Step 1: Add the failing assertion to the existing native icon application test**

In `testNativeIconApplicationPreservesExactAttentionCountAndAccessibility`, bind the unwrapped image once and add the image-size assertion before asserting that it is a template:

```swift
let image = try XCTUnwrap(button.image)
XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
XCTAssertTrue(image.isTemplate)
```

Keep the existing title, alpha, image-position, accessibility label, and accessibility-value assertions unchanged.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/StatusItemControllerTests/testNativeIconApplicationPreservesExactAttentionCountAndAccessibility
```

Expected: FAIL because the current image size is `NSSize(width: 20, height: 18)`, which includes the status-dot margin, rather than `NSSize(width: 18, height: 18)`.

- [ ] **Step 3: Do not alter production code in this task**

Leave the implementation unchanged so the next task starts from the observed red test.

- [ ] **Step 4: Commit the red test only**

```bash
git add HerdrMenubarTests/StatusItemControllerTests.swift
git commit -m "test: specify dot-free status icon geometry"
```

---

### Task 2: Remove dot-specific state and render only the terminal icon

**Files:**

- Modify: `HerdrMenubar/Menu/MenuBarIcon.swift:3-121`
- Modify: `HerdrMenubar/Menu/StatusItemController.swift:314-388`
- Modify: `HerdrMenubarTests/MenuBarIconTests.swift:18-101`
- Modify: `HerdrMenubarTests/StatusItemControllerTests.swift:324-348`

**Interfaces:**

- Consumes: `ConnectionState`, `MenuBarIconPresentation`, and `NativeStatusItemIconRenderer.apply(_:accessibilityValue:to:)`.
- Produces: `MenuBarIconPresentation` with `mode`, `opacity`, `attentionCount`, and `showsAttentionCount`; `NativeStatusItemIconContent` with only `opacity` and `title`.

- [ ] **Step 1: Remove light-style expectations from the presentation tests**

In `HerdrMenubarTests/MenuBarIconTests.swift`, rename the two affected tests and remove only their `lightStyle` assertions:

```swift
func testConnectedClearPresentationIsOpaqueAndAccessibleWithNoAttentionText() {
    let presentation = MenuBarIconPresentation(connectionState: .connected, attentionCount: 0)
    XCTAssertEqual(presentation.mode, .clear)
    XCTAssertEqual(presentation.opacity, 1)
    XCTAssertEqual(presentation.attentionCount, 0)
    XCTAssertFalse(presentation.showsAttentionCount)
    XCTAssertEqual(
        MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 0),
        "Connected, no agents need attention"
    )
}

func testConnectedAttentionPresentationShowsCountAndUsesSingularAccessibilityText() {
    let presentation = MenuBarIconPresentation(connectionState: .connected, attentionCount: 1)
    XCTAssertEqual(presentation.mode, .attention)
    XCTAssertEqual(presentation.opacity, 1)
    XCTAssertTrue(presentation.showsAttentionCount)
    XCTAssertEqual(
        MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 1),
        "Connected, 1 agent needs attention"
    )
}
```

In `assertDisconnected`, remove `XCTAssertEqual(presentation.lightStyle, .hollow)` and retain the mode, opacity, count, visibility, and accessibility assertions.

- [ ] **Step 2: Replace the native-content test with dot-free state mapping**

Rename `testNativeIconContentMapsEveryStatusLightStyleAndCount` to `testNativeIconContentMapsEveryStateToOpacityAndCount`. Replace its three expected values with:

```swift
XCTAssertEqual(
    NativeStatusItemIconRenderer.content(for: disconnected),
    NativeStatusItemIconContent(opacity: 0.55, title: "")
)
XCTAssertEqual(
    NativeStatusItemIconRenderer.content(for: clear),
    NativeStatusItemIconContent(opacity: 1, title: "")
)
XCTAssertEqual(
    NativeStatusItemIconRenderer.content(for: attention),
    NativeStatusItemIconContent(opacity: 1, title: "23")
)
```

- [ ] **Step 3: Remove the dot model and SwiftUI overlay**

In `HerdrMenubar/Menu/MenuBarIcon.swift`:

1. Delete the entire `LightStyle` enum.
2. Delete `let lightStyle: LightStyle`.
3. Delete all three `lightStyle = …` assignments from the initializer.
4. Replace the body’s leading icon with the terminal symbol directly:

```swift
Image(systemName: "terminal")
    .font(.system(size: 16, weight: .regular))
```

5. Delete the entire `TerminalStatusIcon` type, including `statusLight` and all circle drawing.

Do not modify `Mode`, opacity assignments, count visibility assignments, `HStack(spacing: 2)`, or accessibility modifiers.

- [ ] **Step 4: Remove the AppKit dot renderer**

In `HerdrMenubar/Menu/StatusItemController.swift`, replace the native content model and construction with:

```swift
struct NativeStatusItemIconContent: Equatable {
    let opacity: Double
    let title: String
}

static func content(
    for presentation: MenuBarIconPresentation
) -> NativeStatusItemIconContent {
    NativeStatusItemIconContent(
        opacity: presentation.opacity,
        title: presentation.showsAttentionCount
            ? String(presentation.attentionCount)
            : ""
    )
}
```

In `apply`, replace:

```swift
button.image = makeImage(lightStyle: content.lightStyle)
```

with:

```swift
button.image = makeImage()
```

Replace `makeImage(lightStyle:)` with this terminal-only implementation:

```swift
private static func makeImage() -> NSImage? {
    guard let terminal = NSImage(
        systemSymbolName: "terminal",
        accessibilityDescription: "Herdr terminal status"
    )?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else {
        return nil
    }
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.set()
        terminal.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
        return true
    }
    image.isTemplate = true
    return image
}
```

Delete the diameter switch, `NSBezierPath`, stroke/fill branches, and all light-style references. Keep the template-image assignment.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run both focused commands from **Shared commands**. Expected: both pass; the native image test reports an 18-by-18 template image, connected attention renders title `23`, and unavailable states render title `""` at opacity `0.55`.

- [ ] **Step 6: Run the full non-UI suite**

Run the **Full non-UI suite** command. Expected: `** TEST SUCCEEDED **` with no test failures.

- [ ] **Step 7: Build, install, and relaunch the validated app**

Run:

```bash
./scripts/install.sh
```

Expected: `** BUILD SUCCEEDED **`, followed by an installation at `~/Applications/Herdr Menubar.app` and `Launched Herdr Menubar.` Verify that the menu-bar icon has no status dot; when attention exists it shows the terminal icon followed by the count.

- [ ] **Step 8: Commit the implementation**

```bash
git add \
  HerdrMenubar/Menu/MenuBarIcon.swift \
  HerdrMenubar/Menu/StatusItemController.swift \
  HerdrMenubarTests/MenuBarIconTests.swift \
  HerdrMenubarTests/StatusItemControllerTests.swift
git commit -m "feat: simplify menu bar status indicator"
```
