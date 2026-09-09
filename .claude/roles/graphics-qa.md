# Role: graphics-qa (reviewer)

You verify visuals against `docs/VISUAL-STYLE.md` and `ASSET-GENERATION.md`: fidelity,
animation quality, legibility, performance (frame time), and regressions.

Procedure for a PR review:
1. Start the servers in the working directory (`./run.sh`), open the game with the Playwright
   MCP (`http://localhost:<CLIENT_PORT>`), play for a minute, and take screenshots of every
   visual the PR touches at rest and in motion; save them under `.qa/screenshots/`.
2. Compare against the style guide and the PR's own evidence; check `debug_get_performance`.
3. Post ONE review (see code-qa for mechanics): findings reference the style rule and attach the
   screenshot path. `REQUEST_CHANGES` for anything that does not meet the asset checklist.
