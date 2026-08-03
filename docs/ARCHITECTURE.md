# Architecture

## System context

The Issue Tracker is a small service-oriented application. Browser requests enter through the React UI and API Gateway. The gateway validates bearer tokens and routes requests to the service that owns the resource.

```text
Browser -> React UI -> API Gateway (:8096)
                           |-- /auth/**   -> Auth service (:8097)  -> authdb
                           `-- /issues/** -> Issue service (:8098) -> issuedb
```

MySQL stores authentication and issue data in separate databases. Services do not read each other's database.

## Module ownership

| Module | Responsibility | Main entry point |
|---|---|---|
| `api-gateway` | Routing, CORS, JWT validation | `ApiGatewayApplication` |
| `auth-service` | Registration, login, users, roles | `AuthServiceApplication` |
| `issue-service` | Issue lifecycle, status history | `IssueServiceApplication` |
| `frontend-service` | Browser UI and API client | `src/App.js` |

## Backend layering

Both domain services follow the same dependency direction:

```text
controller -> service -> repository -> entity
     |           |
     `---------- DTO
```

- Controllers own HTTP semantics and validation boundaries.
- Services own business rules and transactions.
- Repositories own persistence queries.
- DTOs are the external contract; entities remain internal.
- Exception handlers translate domain errors into HTTP responses.

## Security boundary

The auth service issues HS256-signed JWTs. The gateway and both domain services must receive the same `JWT_SECRET`. The gateway is the public API entry point, but each service also enforces authorization so direct network access does not bypass security.

Never store a real JWT secret or database password in source control. Use deployment environment variables.

## Change placement

- Authentication, user, or role behavior belongs in `auth-service`.
- Issue state, validation, or history belongs in `issue-service`.
- Cross-origin policy and route changes belong in `api-gateway`.
- UI state and HTTP client calls belong in `frontend-service`; keep requests in `src/api/`.
- Changes to an HTTP contract should update its DTO, controller/service tests, frontend API client, and documentation together.
