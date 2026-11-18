---
name: test-behavior-not-implementation
description: Use when writing or reviewing a test, especially one built on mocks.
---

# Test Behavior, Not Implementation

## The one question

**Would this test still pass if every function it calls returned `undefined`?**

If yes, it tests nothing. This is the most common failure in an agent-written suite, because a test that mocks its way to green is much easier to write than one that exercises the thing.

## Five shapes that pass while proving nothing

1. **Mock-and-assert-the-mock.** `expect(mockFn).toHaveBeenCalledWith(...)` where `mockFn` is the only thing under test. It asserts you wrote the call you just wrote.
2. **No assertion.** The test runs the code and ends. It catches a throw, nothing else. Say so if that is the intent.
3. **Asserting the setup.** Every value checked was assigned by the test itself.
4. **Snapshot of everything.** A snapshot nobody reads is a change-detector, not a test. Snapshot the thing that matters, and read the diff.
5. **Pinned environment that makes the bug unreachable.** A date test pinned to `TZ=UTC` cannot observe a daylight-saving off-by-one. Pin to an environment where the bug is *possible*.

## Write it so it can fail

- Assert on the **observable result**: the returned value, the stored row, the rendered text, the status code.
- Mock only what you cannot run: a third-party network call, a clock, a payment provider. Never mock the unit under test.
- Before committing, break the implementation deliberately and confirm the test goes red. If it does not, the test is decoration.

## A test that pins a defect

A test asserting that wrong behaviour is correct (say, that an exposed credential is accepted) is worse than no test: the next agent "fixes" the code back to make it pass. Delete or invert that assertion as part of the fix.

## In a mostly-mocked suite

Count before you quote: how many test files mock, how many render or call the real thing. When touching a mock-heavy area, convert one test to a behaviour test rather than adding another mock-based one.
