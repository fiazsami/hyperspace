# Agent Instructions

This repository is a fork, and it is consumed as a git submodule of
`fiazsami/screen-savers`. Both facts change how work lands here, so read this
before committing.

## Branch policy

**Never commit to `master`.** It is this repository's default branch, and every
change reaches it through a pull request. Branches are `<type>/<topic>`, where
`<type>` is one of `feat`, `fix`, `chore`, `docs`, `test`.

```bash
git switch master && git pull --ff-only
git switch -c <type>/<topic>
# ... change, run the tests ...
git push -u origin <type>/<topic>
gh pr create -R fiazsami/hyperspace --base master --draft   # a draft, always
```

Pass `-R fiazsami/hyperspace` explicitly. This repo is a fork, and `gh` resolves the
base repository to the **parent** in a fork clone — without it you can open a
pull request on the upstream project by accident.

**Open every PR as a draft, and stop at `gh pr ready`.** An open PR says nothing
about whether it has been reviewed, so "still being reviewed" and "ready to
merge" look identical to whoever is watching. Draft makes the difference visible
where the merge decision is made, and GitHub refuses to merge a draft. Run
`gh pr ready` only once review is clean; merging is a separate decision taken
after that, never in the same motion.

Review here is not a GitHub app — none has ever posted on this repository. It is
an agent running `/code-review` against the diff, which is why draft state
cannot deadlock it: there is no trigger to skip. CI is unaffected too; the
`tests` workflow uses bare `on: pull_request`, which fires for drafts.

This repository shares a C++ core with its twin. A change to that core is a PR
in **both**, and they leave draft together or neither does — marking one ready
while the other is still a draft leaves the two `master` branches disagreeing
and the superproject unable to bump its pointers coherently.

Never commit from a detached HEAD. The superproject checks this repo out
detached when it records a submodule pointer, and a commit made in that state
lands on no branch at all.

## A change here is two pull requests

1. This one, merged to `master`.
2. A second in `fiazsami/screen-savers` moving the submodule pointer to the
   **merge commit** of the first — never the branch tip, which a squash rewrites.

Do not bump the pointer to a commit that is not yet on `master`; it pins the
superproject to a sha that can vanish.

## Tests

```
tests/harness.h        CHECK / CHECK_NEAR, and the case registry
tests/main.cpp         the only main() in this repo
tests/test_<topic>.*   one file per topic, no main()
```

Cases register through `__attribute__((constructor))`, so the header works from
C, C++ and Objective-C alike. Adding a file to `tests/` is the whole
registration step. `.github/workflows/tests.yml` builds and runs the suite on
every pull request.

**That workflow is a smoke test, not the coverage gate.** The gate lives in the
superproject — `tools/coverage.sh` and `coverage/hyperspace.json`, which hold the source
list, the include paths and the ratchet baseline. A pull request here cannot
tell you whether coverage held; that is measured after this merges, in the
superproject. Treat the review of a PR in this repo accordingly: it is the last
review that can stop the change, because by the time the measurement runs, this
is already on `master`.

Before committing a test, break the function it covers on purpose and confirm the
test fails, then restore the source and confirm `git diff` is empty. A test that
passes against a broken function is not testing what you think.
