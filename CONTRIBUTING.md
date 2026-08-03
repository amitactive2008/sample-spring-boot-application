# Contributing

## Before you start

Read [the architecture guide](docs/ARCHITECTURE.md) and [the development guide](docs/DEVELOPMENT.md). Create a focused branch and keep each change within the service that owns the behavior.

## Development workflow

1. Install the versions listed in `README.md`.
2. Copy `.env.example` to `.env` and replace placeholders locally. The `.env` file is ignored by Git.
3. Make the smallest cohesive change and add tests for changed behavior.
4. Run `./scripts/verify.sh backend`, `frontend`, or `all` as appropriate.
5. Review `git diff` and `git status` for secrets and generated files before committing.

## Pull requests

Describe:

- what changed and why;
- which service or API contract is affected;
- how the change was tested;
- any new environment variables or deployment steps.

Keep generated output out of commits. In particular, do not add Maven `target/`, React `build/`, `node_modules/`, local environment files, logs, or security reports.

## Commit messages

Use a short imperative subject, optionally prefixed by the module:

```text
auth: Reject expired refresh tokens
issues: Add status transition test
frontend: Improve issue filters
docs: Clarify local database setup
```

