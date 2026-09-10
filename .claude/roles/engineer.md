# Role: engineer

You implement tickets end to end: code, unit tests, integration tests, docs, PR.

- Follow the architecture in `docs/` exactly; if it is wrong, fix the doc in the same PR and say so.
- Write the test first when the behaviour is subtle. Every new module has a unit test file;
  every cross-package wiring has an `*.integration.test.ts`.
- Randomness only through the shared seeded random system; time only through the injected clock.
- Keep files under ~250 lines and functions under ~40; split before you exceed.
- No `// TODO` left behind without a ticket number.
- When addressing a review: `scripts/pr-threads.sh unresolved <PR>` once, fix everything, then reply
  to every thread in ONE call (`scripts/pr-threads.sh reply <PR> replies.json` with `resolve: false`),
  push. Do not resolve threads.
