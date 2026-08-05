# Architecture

## System context

Issue Tracker v3 runs in a local kind cluster. Browser traffic enters through nginx
Ingress, which serves the React application and forwards `/api/**` to the API gateway.

```text
Browser -> nginx Ingress (:80)
             |-- /       -> frontend-service (:3000)
             `-- /api/** -> api-gateway (:8096)
                                |-- /auth/**   -> auth-service (:8097)
                                `-- /issues/** -> issue-service (:8098)

auth-service  ----\
                    +--> MySQL (:3306, persistent volume)
issue-service -----/
```

All application resources use the `issue-app` namespace. Kubernetes Services provide
stable DNS names; pods do not address one another by IP.

## Module ownership

| Module | Responsibility | Runtime |
|---|---|---|
| `api-gateway` | JWT validation, authorization, CORS, and edge routing | Java 17, WebFlux |
| `auth-service` | Login, registration, users, roles, and token issuance | Java 21, MVC/JPA |
| `issue-service` | Issue lifecycle, search, status transitions, and history | Java 21, MVC/JPA |
| `frontend-service` | Browser UI, session state, and API clients | React |
| `kubernetes/base` | Environment-neutral application workloads and services | Kustomize base |
| `kubernetes/environments/kind` | Local ingress, MySQL, storage, secrets, and patches | kind overlay |

## Application dependency direction

```text
controller -> service -> repository -> entity
     |           |
     `---------- DTO
```

Controllers own HTTP semantics, services own business rules, repositories own persistence,
and DTOs form the external contract. Services communicate over HTTP rather than through
shared source packages or cross-service repository access.

## Kubernetes configuration model

The base describes production-shaped Deployments, Services, ConfigMaps, ExternalSecrets,
storage, and ingress. The kind overlay deliberately selects only portable base resources,
then adds local MySQL, nginx Ingress, development Secrets, and targeted patches.

When changing Kubernetes configuration:

1. Put portable workload behavior in `kubernetes/base/`.
2. Put local-only differences in `kubernetes/environments/kind/`.
3. Keep patch targets explicit.
4. Render the overlay before deployment with `./scripts/verify.sh manifests`.

## Security boundaries

The auth service issues JWTs. The gateway and domain services validate them, and all
backend workloads must receive the same signing secret. The kind credentials are obvious
development-only placeholders; production values belong in an external secret provider.

Do not commit real Secret manifests, exported kubeconfigs, scanner workspaces, generated
reports, or rendered Kubernetes output.

## Image delivery

Each service owns its Dockerfile. `scripts/kind-deploy.sh` builds images with Podman, loads
them into kind's containerd image store, and applies the rendered overlay. The overlay uses
`imagePullPolicy: Never` so Kubernetes consumes the locally loaded tags.
