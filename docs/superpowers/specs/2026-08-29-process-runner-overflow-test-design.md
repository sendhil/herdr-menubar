# Process Runner Overflow Test Stabilization Design

**Date:** 2026-08-29

## Problem

`BoundedProcessRunnerTests.testSimultaneousStdoutAndStderrOverflowTerminatesExactlyOnce` starts its one-second process deadline before its Python fixture has completed startup and written its readiness marker. On a cold or contended Xcode test run, fixture startup can consume that budget, allowing `.timedOut` to win before either output reader reports its intended overflow.

The failure is test-only: the focused process-runner class passes, including this test, once Python is warm. The existing terminal-error assertion already measures the intended behavior only after readiness.

## Options considered

1. **Increase only the process deadline and readiness allowance (chosen).** Set both from one second to five seconds. Keep the existing post-readiness requirement that the overflow result arrives in less than one second. This removes cold-start timing from the terminal-error race without weakening the behavior under test.
2. **Replace the Python fixture with a shell fixture.** This may start faster, but it makes deterministic simultaneous stdout/stderr writes substantially harder and risks weakening the concurrent-overflow coverage.
3. **Add reader-readiness synchronization to production code.** This expands the runner interface and production behavior solely to stabilize a test. It is disproportionate and unnecessary because pipe output persists until the existing readers consume it.

## Design

Modify only `HerdrMenubarTests/BoundedProcessRunnerTests.swift` in the simultaneous-overflow test:

- Change `ProcessInvocation.deadline` from `.seconds(1)` to `.seconds(5)`.
- Change the fixture readiness wait from `.seconds(1)` to `.seconds(5)`.
- Preserve the current assertion that, once ready, the runner produces one overflow terminal error in less than one second.
- Preserve the one-process launch count and exact `term\n` marker assertions.

No production source, public API, process lifecycle behavior, or installed-app behavior changes.

## Validation

1. Run the isolated simultaneous-overflow test to demonstrate the prior one-second configuration fails with `.timedOut` on this machine.
2. Make the test-only timeout correction.
3. Run the isolated test repeatedly enough to exercise cold and warm starts.
4. Run the complete `BoundedProcessRunnerTests` class.
5. Run the full `HerdrMenubarTests` suite before returning to the pending status-icon installation.

## Non-goals

- Changing `BoundedProcessRunner` production code.
- Removing the Python fixture or reducing concurrent stdout/stderr coverage.
- Changing the status-icon implementation while this test gate is unresolved.
