# Process Runner Overflow Test Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Python fixture startup time from incorrectly producing a deadline failure in the simultaneous stdout/stderr overflow test.

**Architecture:** This is a test-only timing-contract correction. The fixture receives enough time to start and signal readiness, while the existing post-readiness assertion continues to prove that a concurrent output overflow is detected and terminated quickly. `BoundedProcessRunner` production code is unchanged.

**Tech Stack:** Swift 6, XCTest, Foundation, Darwin, Xcode 26/macOS 26.

**Design spec:** `docs/superpowers/specs/2026-08-29-process-runner-overflow-test-design.md`

## Global Constraints

- Modify only `HerdrMenubarTests/BoundedProcessRunnerTests.swift` for this stabilization.
- Do not alter `HerdrMenubar/System/BoundedProcessRunner.swift` or any process-runner public interface.
- Retain the Python fixture, concurrent writes, overflow-error assertion, post-readiness `< 1 second` duration assertion, TERM marker assertion, and process-reaping assertion.
- The timeout changes must permit fixture startup only; they must not weaken the overflow-detection bound after readiness.

---

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubarTests/BoundedProcessRunnerTests.swift` | Defines the concurrent Python fixture, its startup wait, deadline, and terminal-overflow behavior assertions. |

## Shared commands

Isolated race test:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/BoundedProcessRunnerTests/testSimultaneousStdoutAndStderrOverflowTerminatesExactlyOnce
```

Full process-runner class:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/BoundedProcessRunnerTests
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

### Task 1: Stabilize the fixture-startup allowance without weakening overflow detection

**Files:**

- Modify: `HerdrMenubarTests/BoundedProcessRunnerTests.swift:152-161`

**Interfaces:**

- Consumes: `ProcessInvocation(deadline:stdoutLimit:stderrLimit:)`, `assertFileAppears(_:within:)`, and the existing `BoundedProcessOperation` test helper.
- Produces: a simultaneous-overflow test that gives the Python fixture five seconds to start, but still requires overflow termination in less than one second after the fixture is ready.

- [ ] **Step 1: Record the failing one-second baseline**

Run the isolated race-test command from **Shared commands** without changing source. Record that the current test can fail because `assertFileAppears(readyMarker, within: .seconds(1))` does not observe readiness before the runner’s `.seconds(1)` deadline yields `.timedOut`.

- [ ] **Step 2: Change only the startup/deadline allowances**

In `testSimultaneousStdoutAndStderrOverflowTerminatesExactlyOnce`, change the invocation deadline and readiness wait exactly as follows:

```swift
let request = ProcessInvocation(
    executableURL: fixture.url,
    arguments: [termMarker.path, readyMarker.path],
    deadline: .seconds(5),
    stdoutLimit: 64,
    stderrLimit: 64
)
let operation = runner.start(request)

await assertFileAppears(readyMarker, within: .seconds(5))
```

Do not change `started`, `XCTAssertLessThan(elapsed, .seconds(1))`, the accepted overflow errors, the `term\n` marker assertion, or the PID/reaping assertion.

- [ ] **Step 3: Run the isolated test twice and verify GREEN**

Run the isolated race-test command twice as separate invocations. Expected each time: `** TEST SUCCEEDED **`; the test observes readiness, returns either `.stdoutLimitExceeded` or `.stderrLimitExceeded`, writes exactly `term\n`, and completes its post-readiness path in less than one second.

- [ ] **Step 4: Run the complete process-runner test class**

Run the full process-runner class command from **Shared commands**. Expected: all `BoundedProcessRunnerTests` pass, including standard descriptor normalization, cancellation, deadlines, output limits, and child reaping.

- [ ] **Step 5: Run the full non-UI suite**

Run the full non-UI suite command from **Shared commands**. Expected: `** TEST SUCCEEDED **` with no failures. This reopens the validation gate for the pending dot-free menu-bar icon implementation.

- [ ] **Step 6: Commit the test-only correction**

```bash
git add HerdrMenubarTests/BoundedProcessRunnerTests.swift
git commit -m "test: stabilize concurrent output overflow fixture"
```

Do not stage the pending status-icon files in this commit.
