import { defineConfig } from 'vitest/config';
import { coverageOptions, testTierOptions } from '../../vitest.tiers';

// docs/ENGINEERING.md §2.5: the floor is what the package achieves today and only ever moves up.
const COVERAGE_THRESHOLDS = { lines: 40, branches: 95, functions: 75, statements: 40 };

export default defineConfig({
  test: {
    globals: true,
    ...testTierOptions(),
    coverage: coverageOptions(COVERAGE_THRESHOLDS),
  },
});
