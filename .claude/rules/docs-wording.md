# Docs wording

Documentation is read after the release, so it is written as of the release. This covers the README, `docs/*.md`,
a service's own README and docs, Postman descriptions and CHANGELOG entries.

- Describe what the version in `VERSION` does, in the present tense. The PR that bumps `VERSION` ships with its docs,
  so the docs are released together with the code.
- Do not write "unreleased", "not yet released", "will be active once deployed", "once this PR merges", "the next
  release will" or similar. The only place for "Unreleased" is a CHANGELOG heading before the release PR dates it.
- What a released version does not do yet is a divergence, written as `contract-changes.md` says ("Not yet wired",
  "Known gap"), naming the version that lacks it, e.g. "Session `5.0.0` still publishes `session.started`".
- Merge order, pending reviews and other PRs belong in the PR body, not in the docs.
- Before opening a release or delivery PR, search the changed docs for these phrases and rewrite them.
