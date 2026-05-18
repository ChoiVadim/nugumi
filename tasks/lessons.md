# Lessons

- When building onboarding or setup UI, include a repeatable entry point before calling it done. A permission window that only appears on first-run is hard to QA and prevents users from reviewing instructions later.
- Keep first-run setup mode separate from manual review mode. If a setup window can be reopened after everything is complete, its primary CTA must have an explicit complete-state action like closing the window instead of recomputing the setup path.
- Status indicators in onboarding cards must not look like clickable buttons. Use quiet labels or icons for states like done/later; reserve filled capsules for real actions only.
- Permission setup is not enough for onboarding. New users also need a short product tour that explains the core actions, the exact clicks or shortcuts, and shows the same feature media used on the landing page.
- In feature onboarding, teach the primary gesture first. For Nugumi translate/rewrite, left-click and right-click are more important than keyboard shortcuts; shortcuts should be secondary fallback copy.
