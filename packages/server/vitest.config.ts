import { defineConfig } from 'vitest/config';
import { coverageOptions, testTierOptions } from '../../vitest.tiers';

// docs/TESTING.md: the floor is what the package achieves today and only ever moves up.
const COVERAGE_THRESHOLDS = { lines: 49, branches: 74, functions: 70, statements: 49 };

export default defineConfig({
  test: {
    globals: true,
    ...testTierOptions(),
    coverage: coverageOptions(COVERAGE_THRESHOLDS),
  },
});
