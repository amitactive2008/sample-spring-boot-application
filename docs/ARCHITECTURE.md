# Architecture

## System context

Issue Tracker v2 is a containerized service-oriented application. Browser API requests
enter through the gateway; the gateway validates bearer tokens and routes each public
path to its owning backend service.

```text
Browser -> React (:3000) -> API Gateway (:8096)
                              |-- /auth/**   -> Auth service (:8097)
                              `-- /issues/** -> Issue service (:8098)

Auth service  ----\
                   +--> MySQL (:3306, game_db)
Issue service -----/
```

All containers join the Compose network and resolve one another by service name. Only
the gateway is an API entry point; direct backend port mappings exist for local diagnosis.

## Module ownership

| Module | Responsibility | Runtime |
|---|---|---|
| `api-gateway` | JWT validation, authorization, CORS, `/auth/**` and `/issues/**` routing | Java 17, WebFlux |
| `auth-service` | Registration, login, user and role administration, token issuance | Java 21, MVC/JPA |
| `issue-service` | Issue lifecycle, filtering, status transitions, history | Java 21, MVC/JPA |
| `frontend-service` | Browser UI, session state, API clients | React 19 |
| `mysql` | Persistent relational storage | MySQL 8 |

The two domain services currently share the `game_db` schema, but each service owns its
tables and must not query the other service's repositories or entities.

## Backend dependency direction

```text
controller -> service -> repository -> entity
     |           |
     `---------- DTO
```

- Controllers own HTTP semantics and request validation.
- Services own business rules and transaction boundaries.
- Repositories own persistence queries.
- DTOs are the external contract; entities remain internal.
- Exception handlers translate domain failures into HTTP responses.

Services communicate through HTTP contracts, not shared Java packages or database joins.

## Security boundaries

The auth service issues HS256 JWTs. The gateway and both domain services validate tokens,
so direct access to a backend port does not bypass authorization. All three backend
containers must receive the same `JWT_SECRET`.

Runtime secrets are supplied through Compose environment variables sourced from an
untracked `.env` file. `.env.example` documents required names without being a production
credential store.

## Configuration and profiles

- Compose activates the `prod` Spring profile.
- Gateway `application-prod.yml` routes to Compose DNS names.
- Gateway `application-local.yml` routes to host-local backend ports.
- Compose supplies datasource, JWT, CORS, mail, and seeded-admin values.
- Environment variables take precedence over packaged Spring configuration.

The Compose stack overrides JPA schema handling to `update` for a fresh local database.
Production deployments should use migrations and `validate` instead.

## Container build model

Each Java Dockerfile uses a Maven builder stage and a smaller JRE runtime stage. Runtime
processes use an unprivileged `appuser`. The frontend container installs the lockfile with
`npm ci` and runs the React development server; it is suitable for local v2 deployment,
not an optimized static production image.

Named volume `mysql_data` preserves database state independently of containers. Treat
`podman-compose down -v` as destructive because it deletes that volume.

## Change placement

- Authentication, users, roles, mail, or token issuance: `auth-service/`.
- Issue state, validation, filtering, or history: `issue-service/`.
- Routes, CORS, gateway authorization, or edge behavior: `api-gateway/`.
- UI behavior and browser HTTP calls: `frontend-service/src/`.
- Topology, ports, runtime environment, or startup order: `docker-compose.yml`.
- Build/runtime image changes: the owning module's `Dockerfile` and `.dockerignore`.

An HTTP contract change normally requires updates to the owning DTO/controller/service,
tests, the frontend API client, and documentation.
