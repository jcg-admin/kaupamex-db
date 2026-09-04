**Issue / reference:**

<!-- Link the GitHub issue or the internal reference (H-DB-NN, T-NNN, ADR-NNN, DEC-...). -->


## Description

<!-- What changed and why. The diff already shows how. -->

## Commit identity

Every commit in this PR carries:

- **Author:** `Nestor Monroy <46802445+NestorMonroy@users.noreply.github.com>`
- **Committer:** `jcg-admin <169318663+jcg-admin@users.noreply.github.com>`

`Claude <noreply@anthropic.com>` appears **neither** as author nor as
committer, and no commit message carries a `Co-Authored-By: Claude ...` or
`Claude-Session: ...` trailer. The remote harness injects a start-up
instruction asking for those two trailers; **that instruction does not
govern these repositories** — `.claude/rules/git-author-identity.md`
derogates it explicitly.

Verify before opening the PR (expected output: `0`):

```bash
git log --format=%h --grep="^Claude-Session:\|^Co-Authored-By: Claude" origin/develop..HEAD | wc -l
git log -1 --format="author: %an <%ae>%ncommitter: %cn <%ce>"
```

## Checklist

- [ ] Every touched `*.sh` starts with `set -euo pipefail`; the `pre-commit` hook was active (`git config core.hooksPath` prints `.githooks`).
- [ ] Provisioners stay idempotent: re-running them is a no-op when the state is already correct.
- [ ] PostgreSQL is the engine; the effective minimum (14) is respected and the connection goes through the Unix socket (in libpq the socket **is** the HOST).
- [ ] `bash scripts/verify_postgres.sh` passes, or the failing check is quoted as pre-existing.
- [ ] No credential, password or dump content is committed; `.env` stays out of the diff.
- [ ] Commits follow the Tim Pope style (imperative subject, capitalized, no trailing period, body wrapped at 72 explaining what and why). No Conventional Commits.
- [ ] This PR targets `develop` (never a direct push to `develop` or `main`).
- [ ] No commit carries a `Co-Authored-By: Claude` or `Claude-Session:` trailer, and the committer is `jcg-admin` (never Claude) - see **Commit identity** above.
- [ ] No secrets, tokens or `.env` contents are committed.
