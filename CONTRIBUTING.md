# Contributing

## Before changing code

Read [README.md](README.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and
the module that owns the behavior. Keep changes focused and avoid moving logic
between services unless the service boundary itself is intentionally changing.

Create local configuration from the committed template:

```bash
cp .env.example .env
```

Never commit `.env`, tokens, generated reports, build output, or scanner caches.

## Development workflow

1. Make the smallest coherent change in the owning module.
2. Add or update tests for behavior changes.
3. Update documentation when commands, routes, ports, variables, or architecture change.
4. Run the relevant verification scope:

   ```bash
   ./scripts/verify.sh backend
   ./scripts/verify.sh frontend
   ./scripts/verify.sh helm
   ./scripts/verify.sh shell
   ```

5. Before opening a pull request, run `./scripts/verify.sh all` and review
   `git status --short` for generated or sensitive files.

## Commit guidance

Use focused commits with imperative subjects, for example:

```text
Fix Kubernetes backend service routing
Document Podman Helm deployment
Add issue status transition test
```

Do not mix unrelated formatting, generated output, or local configuration into
the same commit.
