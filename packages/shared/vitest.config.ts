import { defineConfig } from 'vitest/config';
import { coverageOptions, testTierOptions } from '../../vitest.tiers';

// docs/TESTING.md: the floor is what the package achieves today and only ever moves up.
const COVERAGE_THRESHOLDS = { lines: 40, branches: 100, functions: 75, statements: 40 };

export default defineConfig({
  test: {
    globals: true,
    ...testTierOptions(),
    coverage: coverageOptions(COVERAGE_THRESHOLDS),
  },
});
