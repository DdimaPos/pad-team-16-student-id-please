`main` and `dev` are protected: no direct pushes, PR required.

Branch naming convention is the following:

```
<type of task>/<issue number>-<task brief description>
```

| Prefix      | Purpose                   | Example                           |
| ----------- | ------------------------- | --------------------------------- |
| `features/` | New functionality         | `features/23-user-authentication` |
| `bugs/`     | Bug fixes                 | `bugs/15-header-alignment`        |
| `hotfix/`   | Critical production fixes | `hotfix/18-server-crash`          |
| `chore/`    | Maintenance tasks         | `chore/9-dependency-updates`      |

Always create the branches from latest dev, never from main except hotfix branches.

### Naming Guidelines

- Use lowercase letters and hyphens
- Keep descriptions concise but descriptive
- Always include the related issue number

Commit message convention is the following:

```
<type of change>(#<issue number>): <message>

Examples:

feat(#18, #19): player service and server session service
feat(#16): applicant service delivery — docs/ and submodule pointer
chore(#5): sync submodules pointers for all services READMEs
```

Allowed types of change: `feat`, `bugs`, `chore`, `docs`, `hotfix`.

Do not add a `Co-Authored-By` trailer from Claude or any other AI tool to commits, or `Created by` /
`Generated with` in PRs (since 2026-10-25). `Co-authored-by` lines of people that GitHub adds itself when it squashes a branch
with several authors are allowed.

Always keep one commit per branch, meaning after the squash: a PR may have several commits, but it is merged into
`dev` with squash and merge, so one commit reaches `dev`. Suggest squashing or amending. Exceptions are possible,
for example when multiple people colaborate on same branch, and are left to the contributors' discretion.
Update a branch with `git rebase origin/dev`; do not merge `dev` into it (since 2026-10-25). The commit
format is checked on the PR title and on the squash commit that reaches `dev`; commits inside a squashed feature
branch are not checked (follow it anyway). The README section "Rule changes" says which rules are new and which
only clarify how we always worked; earlier work is not counted against a new rule.

### Pull requests

- PRs target `dev`, except `hotfix/` branches, which target `main`, and the release PR `dev` into `main`.
- Merge strategy is squash-and-merge. The release PR `dev` into `main` is a direct PR merged with
  **Create a merge commit**, never squashed (since 2026-10-25); it is exempt from the one-commit rule and
  repeats the `Closes` of everything it ships. From 2026-10-25 its title is `chore(#N): release X.Y.Z` or `Release X.Y.Z`.
- The PR title follows the commit message convention, because squash-and-merge uses it as the
  commit message.
- Every PR closes exactly one issue (`Closes #N`); `Part of` is not used. Split a large story into one issue
  per PR. All issues live in the CPR and are in the project; a PR in a service repository writes
  `Closes DdimaPos/pad-team-16-student-id-please#N` (since 2026-10-25).
- PRs list specific changes and include testing instructions or results (not required for a PR that only
  changes documentation, applies since 2026-10-25) — see `.github/pull_request_template.md`.
- Review: in a repository with several contributors (CPR, Gateway) a review is requested from all other
  human contributors and two approvals are needed (since 2026-10-25). Asking Claude, Copilot or another tool for
  a review as well is not a violation, it is just not required. A private service repository has one human
  contributor, its owner, and Claude or another AI tool is not added to it as a contributor (since 2026-10-25), so no approval is
  required there.

These conventions apply also to submodules, but approves are not required in private repositories.
