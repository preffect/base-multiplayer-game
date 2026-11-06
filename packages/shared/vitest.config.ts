import { defineConfig } from 'vitest/config';
import { coverageOptions, testTierOptions } from '../../vitest.tiers';

// docs/ENGINEERING.md §2.5: the floor is what the package achieves today and only ever moves up.
const COVERAGE_THRESHOLDS = { lines: 40, branches: 100, functions: 100, statements: 50 };

export default defineConfig({
  test: {
    globals: true,
    ...testTierOptions(),
    coverage: coverageOptions(COVERAGE_THRESHOLDS),
  },
});
