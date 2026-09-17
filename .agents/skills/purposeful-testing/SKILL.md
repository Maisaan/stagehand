---
name: purposeful-testing
description: Create, review, or reduce tests while keeping only coverage that protects a concrete behavior, regression, or boundary. Use when adding tests, changing behavior that may need tests, or cleaning an excessive test suite.
---

# Purposeful testing

Use the smallest test set that gives useful confidence. A test needs a named production failure that it would catch. Test count and line coverage are not goals.

Before adding a test, check nearby coverage and ask:

- Can the compiler, type system, or linter already catch this?
- Is the assertion about observable behavior or a stable invariant?
- Is there a plausible regression path?
- Is this the lowest stable layer that proves the behavior once?

If any answer is no, do not add the test unless the user asks for exhaustive coverage.

## What to keep

Prioritize tests for state transitions, data restoration, untrusted persisted input, permission and lifecycle failures, concurrency or cancellation, retries, and safety boundaries. For macOS Accessibility code, trust observed state over setter return values. Cover focus identity, application termination, minimized or unavailable windows, and rollback after partial work.

Use table-driven cases when several inputs enforce one invariant. Keep one strong end-to-end assertion instead of repeating the same behavior through a helper, model, and view.

## What to remove

Remove tests that only assert:

- getters, setters, transparent wrappers, or compiler-enforced types;
- private call sequences without a behavioral consequence;
- exact animation timings, default constants, labels, pixel widths, or view hierarchy details that are not a documented contract;
- successful mocks without checking an outcome;
- branches already covered by a stronger test;
- implementation snapshots that make safe refactors expensive.

Straightforward UI wiring and copy changes usually need no automated test. Put hardware, permission, focus, Spaces, full-screen, and multi-display scenarios in a live acceptance checklist when mocks cannot prove the macOS behavior.

## Workflow

1. Name the regression or invariant before writing code.
2. Search existing tests and keep the strongest owner-level coverage.
3. Add or edit the minimum fixture needed to expose the failure.
4. Assert the observable result and the dangerous negative result.
5. Run the narrow test first, then the relevant suite.
6. Delete superseded tests and helpers in the same change.

Do not add a test merely because production code changed. In the handoff, state what risk each new test covers. If no test is warranted, say why.
