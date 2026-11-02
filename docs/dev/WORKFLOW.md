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
gh pr list                                                    # awaiting review/merge
```
1. Pick the lowest-numbered open milestone's unblocked issue (check its "Depends on" line).
2. Claim it: `gh issue edit N --add-label in-progress`.
3. Branch: `git switch -c issue-N-short-name` (or work in a git worktree).
4. Implement, with tests. Run `scripts/check.sh` until it's green.
5. Add or extend a tutorial chapter if the issue introduced a new Swift/macOS concept (see the issue's "Tutorial" line).
6. Open a PR with `Closes #N` in the body. List any intentional behaviour changes or deviations from PLAN.
7. An independent reviewer (a fresh agent or the owner) reviews it against PLAN, CLAUDE.md and the acceptance criteria. Fix the findings, then merge with a squash.

## Labels
- `decision`: needs the owner's choice. Ask, don't guess. Record the answer in `docs/decisions/`.
- `needs-owner`: needs the owner to act (Apple account, certificates, a manual check).
- `aesthetic`: UI look. Per CLAUDE.md, show the candidates rendered and wait for a pick.
- `trust`: data-loss prevention or crash reporting. Review these with extra care.
- `in-progress`: claimed.

## Trust rules (non-negotiable)
- Never write `book.json` without encode → decode-verify → rotate → atomic write.
- Never modify `Archive/saveNNNN.json` after it's written.
- A failure to load must never half-load or overwrite anything.
- Prefer refusing an operation with a clear error over guessing.
- Never log manuscript text.
