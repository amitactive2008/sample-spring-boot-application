# AI contributor guide

This file is the source of truth for AI coding agents working in the v3 kind branch.

## Read first

Before editing, read `README.md`, `docs/ARCHITECTURE.md`, the owning service, and the
relevant Kustomize base or overlay. Use `rg` and `rg --files` to navigate the repository.

## Repository map

- `api-gateway/`: reactive edge service; validates JWTs and owns public routing.
- `auth-service/`: authentication, user administration, and token issuance.
- `issue-service/`: issue workflows, filtering, and status history.
- `frontend-service/`: React application; HTTP clients live under `src/api/`.
- `kubernetes/base/`: production-shaped Kubernetes resources.
- `kubernetes/environments/kind/`: local kind overlay and development infrastructure.
- `scripts/`: repeatable verification and kind deployment helpers.
- `security-pipeline.sh`: optional extended security and quality pipeline.

## Working rules

1. Keep application changes inside the service that owns the behavior. Do not share Java
   source or repositories across services.
2. Preserve public routes: `/auth/**` belongs to auth-service and `/issues/**` belongs to
   issue-service. External traffic enters through api-gateway.
3. Treat DTOs as API boundaries. Controllers must not expose JPA entities.
4. Keep `kubernetes/base/` environment-neutral. Put kind-only images, storage, ingress,
   credentials, and patches in `kubernetes/environments/kind/`.
5. Never commit real credentials, kubeconfigs, tokens, local environment files, rendered
   manifests, image archives, reports, Maven `target/`, `node_modules/`, or React `build/`.
6. The JWT signing secret must be identical across all backend workloads at runtime.
7. Do not edit `frontend-service/build/`; it is generated and ignored.
8. Update documentation with changes to commands, routes, variables, ports, manifests, or
   deployment relationships.
9. Add or update tests with behavior changes. Prefer the smallest relevant check first.
10. Preserve rootless Podman and kind compatibility.

## Verification

Run checks appropriate to the files changed:

```bash
./scripts/verify.sh backend
./scripts/verify.sh frontend
./scripts/verify.sh manifests
./scripts/verify.sh shell
./scripts/verify.sh all
```

`all` runs every group. If a required local dependency is unavailable, report the exact
command and failure instead of silently skipping it.

## Style

- Java: four-space indentation, constructor injection, focused classes.
- React: functional components, two-space indentation, API calls through `src/api/`.
- Kubernetes: one responsibility per manifest; base resources plus minimal overlays.
- Shell: `set -euo pipefail`, quoted variables, deterministic non-interactive commands.
- Git: focused commits with imperative subjects such as `Validate kind overlay`.
