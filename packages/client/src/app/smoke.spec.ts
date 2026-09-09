import { describe, expect, it } from 'vitest';

// Minimal smoke test so the client unit-test runner (@angular/build:unit-test)
// has a suite to execute before any real game specs exist. Replace / extend
// with component and service specs as the game is built out.
describe('client smoke', () => {
  it('runs the client test toolchain', () => {
    expect(1 + 1).toBe(2);
  });
});
