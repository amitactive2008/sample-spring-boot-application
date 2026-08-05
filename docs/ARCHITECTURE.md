# Architecture

## System context

Issue Tracker is a four-service application deployed locally to a single-node
Kind cluster. Envoy Gateway terminates TLS and routes browser traffic.

```text
Browser -> Kind (:8080/:8443) -> Envoy Gateway
                                     |-- /       -> frontend-service (:3000)
                                     `-- /api/** -> api-gateway (:8096)
                                                           |-- /auth/**   -> auth-service (:8097)
                                                           `-- /issues/** -> issue-service (:8098)

auth-service  ----\
                    +--> MySQL (:3306, persistent volume)
issue-service -----/
```

Kubernetes Services provide stable DNS names. Pods do not address one another
by IP, and all application workloads use the `issue-app` namespace.

## Module ownership

| Module | Responsibility | Runtime |
|---|---|---|
| `api-gateway` | JWT validation, CORS, authorization, and backend routing | Java 17, WebFlux |
| `auth-service` | Login, registration, users, roles, and token issuance | Java 21, MVC/JPA |
| `issue-service` | Issue lifecycle, filtering, status transitions, and history | Java 21, MVC/JPA |
| `frontend-service` | Browser UI, session state, and API clients | React 19 |
| `helm/issue-tracker` | Workloads, services, MySQL, Gateway API, and TLS | Helm 3/4 |
| `kind` | Local cluster and ports `8080 -> 80`, `8443 -> 443` | Kind with Podman |

## Backend dependency direction

```text
controller -> service -> repository -> entity
     |           |
     `---------- DTO
```

Controllers own HTTP semantics, services own business rules, repositories own
persistence, and DTOs form the external contract. Backend services communicate
over HTTP rather than sharing source packages or accessing another service's data.

## Request and authentication flow

The auth service issues HMAC-signed JWTs. The API gateway and domain services
validate those tokens, so every backend must receive the same `JWT_SECRET`.
Envoy strips the external `/api` prefix before forwarding to the gateway; the
gateway then routes `/auth/**` and `/issues/**` to their owning services.

## Deployment configuration

- `helm/issue-tracker/values.yaml` contains local Kind defaults and development placeholders.
- `helm/issue-tracker/values-prod.yaml` contains production-shaped overrides.
- `kind/kind-cluster.yaml` exposes the Envoy listeners to macOS.
- `scripts/helm-deploy.sh` builds with Podman, loads image archives into Kind,
  installs infrastructure, deploys the chart, and verifies the gateway.

Real secrets belong in environment-specific secret management, never in Git.
The local chart values are study/development defaults only.

## Change routing

- Authentication, users, roles, or token issuance: `auth-service/`.
- Issue rules, status transitions, filters, or history: `issue-service/`.
- Edge authorization, CORS, or backend routing: `api-gateway/`.
- Browser behavior or API calls: `frontend-service/`; keep calls in `src/api/`.
- Workload, routing, TLS, or resource settings: `helm/issue-tracker/` and docs.
