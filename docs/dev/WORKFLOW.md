# Working on Scene It (humans and agents)

Read this first when you resume work in a new session.

## Sources of truth
| What | Where |
| --- | --- |
| Product spec | `novel-app-build-bundle/PLAN.md` (wins over the mockup) |
| Deviations from the spec | `docs/decisions/` (wins over PLAN where they conflict) |
| Engineering rules | `CLAUDE.md` |
| Work queue and status | GitHub issues + milestones on `samitbasu/scene-it` |
| Tutorials for the owner | `docs/tutorial/` (a Rust programmer learning Swift/macOS) |

## Picking up work
```sh
gh issue list --milestone "M1 Shell & storage" --state open   # what's left
gh issue list --label decision --state open                   # blocked on the owner
gh issue list --label in-progress                             # claimed by someone
gh pr list --label ready-to-merge                              # reviewed, waiting to be merged
gh pr list                                                    # all open PRs
```
1. Pick the lowest-numbered open milestone's unblocked issue (check its "Depends on" line).
2. Claim it: `gh issue edit N --add-label in-progress`.
3. Branch: `git switch -c issue-N-short-name` (or work in a git worktree).
4. Implement, with tests. Run `scripts/check.sh` until it's green.
5. Add or extend a tutorial chapter if the issue introduced a new Swift/macOS concept (see the issue's "Tutorial" line).
6. If you added or changed a script, update its section in the top-level `README.md` (usage, example arguments, output products).
7. Open a PR with `Closes #N` in the body. List any intentional behaviour changes or deviations from PLAN.
8. An independent reviewer (a fresh agent) reviews the PR against PLAN, CLAUDE.md and the acceptance criteria. Fix the findings and re-run the gate.
9. The **coordinating session** (not the implementing agent) squash-merges once the review is clean and it has re-run `scripts/check.sh` on the PR branch itself. Implementing agents never merge their own work. Work that depends on an unmerged PR may branch from that PR's branch, then rebase with `git rebase --onto origin/main <old-base-tip>` after the squash-merge.

## Labels
- `decision`: needs the owner's choice. Ask, don't guess. Record the answer in `docs/decisions/`.
- `needs-owner`: needs the owner to act (Apple account, certificates, a manual check).
- `aesthetic`: UI look. Per CLAUDE.md, show the candidates rendered and wait for a pick.
- `trust`: data-loss prevention or crash reporting. Review these with extra care.
- `in-progress`: claimed.
- `ready-to-merge`: reviewed and green; waiting for the coordinator to merge.

## Trust rules (non-negotiable)
- Never write `book.md` without serialize → verify (book format §7.2) → rotate → atomic write.
- Never save over a `book.md` that was repaired as it opened until its original bytes are kept
  in `book.md.original-<time>.md` (ADR 0024), and never remove, rotate or prune that file.
- Never modify `Archive/saveNNNN.md` after it's written.
- A failure to load must never half-load or overwrite anything.
- Prefer refusing an operation with a clear error over guessing.
- Never log manuscript text.

## Safety rules for agents (non-negotiable)
- **Never synthesize input** (System Events keystrokes or clicks, `osascript` UI scripting, `cliclick`, CGEvent posting).
  It can reach whatever app is frontmost, including the owner's browser or mail, and the screen may be locked.
  Verify UI through app-hosted tests (XCTest/XCUITest driving our own process) and by reading our own logs or files. If a check needs a human,
  say so in the PR and leave it for the owner.
- Never touch the owner's real data: `~/Library/Application Support/Scene It`, `UserDefaults` for `com.samitbasu.SceneIt`,
  real books, the keychain, certificates, or Xcode accounts. Use temporary directories and the test-host isolation.
- If a manual run of the app leaves state behind (a session marker, recents, a lock file), clean up exactly what you created, and report it.
- Agents share one scratchpad folder. Name temporary files uniquely (include the issue number, e.g. `pr-body-71.md`), never generic names like `pr.md`, because concurrent agents overwrite each other's files.
