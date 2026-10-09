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

Do not add a `Co-Authored-By` trailer to commits or `Created by` in PRs/

Always keep one commit per branch. Suggest squashing or amending. Only exception is when multiple people colaborate on same branch.

### Pull requests

- PRs target `dev`, except `hotfix/` branches, which target `main`.
- Merge strategy is squash-and-merge.
- The PR title follows the commit message convention, because squash-and-merge uses it as the
  commit message.
- PRs must close an issue, list specific changes, and include testing instructions — see
  `.github/pull_request_template.md`.
- Review from all other contributors should be requested

These conventions apply also to submodules.
