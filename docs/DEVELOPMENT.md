# Local development

## Prerequisites

- JDK 21 for auth-service and issue-service
- JDK 17 or newer for api-gateway
- Node.js 18 or newer and npm
- MySQL 8

Each Java module includes its own Maven wrapper, so a global Maven installation is optional.

## Configuration

Create the `authdb` and `issuedb` MySQL databases and an application user with access to both. Copy `.env.example` to `.env` as a reference, then export service-specific values in each terminal. Spring Boot does not automatically load a root `.env` file.

Use a single random `JWT_SECRET` of at least 32 characters for all three backend processes. Do not commit it.

## Run the backend

Start each process in a separate terminal from the repository root.

Auth service:

```bash
cd auth-service
SPRING_PROFILES_ACTIVE=prod \
SPRING_DATASOURCE_URL='jdbc:mysql://localhost:3306/authdb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC' \
SPRING_DATASOURCE_USERNAME=appuser \
SPRING_DATASOURCE_PASSWORD='your-local-password' \
JWT_SECRET='your-local-secret-at-least-32-characters' \
APP_ADMIN_EMAIL='admin@example.com' \
APP_ADMIN_PASSWORD='your-local-admin-password' \
./mvnw spring-boot:run
```

Issue service:

```bash
cd issue-service
SPRING_PROFILES_ACTIVE=prod \
SPRING_DATASOURCE_URL='jdbc:mysql://localhost:3306/issuedb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC' \
SPRING_DATASOURCE_USERNAME=appuser \
SPRING_DATASOURCE_PASSWORD='your-local-password' \
JWT_SECRET='your-local-secret-at-least-32-characters' \
./mvnw spring-boot:run
```

Gateway (the `local` profile routes to localhost):

```bash
cd api-gateway
SPRING_PROFILES_ACTIVE=local \
JWT_SECRET='your-local-secret-at-least-32-characters' \
./mvnw spring-boot:run
```

## Run the frontend

```bash
cd frontend-service
npm ci
REACT_APP_API_BASE_URL=http://localhost:8096 npm start
```

Open `http://localhost:3000`. API traffic is sent to the gateway at port 8096.

## Verify changes

```bash
./scripts/verify.sh backend
./scripts/verify.sh frontend
./scripts/verify.sh all
```

Backend tests use isolated H2 in-memory databases and a test-only signing key, so they do not require MySQL or local secrets. For a narrow change, run a single module directly:

```bash
cd issue-service
./mvnw test
```

```bash
cd frontend-service
npm run lint
npm test -- --watchAll=false --passWithNoTests
```

## Common problems

- `Could not resolve placeholder`: export the variable named in the message.
- API returns 401: confirm that every backend process uses the same `JWT_SECRET`.
- Gateway returns 5xx: confirm both domain services are running and the gateway uses the `local` profile.
- Browser cannot reach the API: set `REACT_APP_API_BASE_URL=http://localhost:8096` before starting or building the frontend.
