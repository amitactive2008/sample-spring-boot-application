# Issue Tracker — v2 Deployment Guide (Podman / Single Box)

Fully containerized deployment of the Issue Tracker application using **Podman** on a
single Linux host. Every component — MySQL, auth-service, issue-service, api-gateway,
and the React frontend — runs as an isolated container. Communication between containers
happens over a shared Podman network; the only port exposed to the host is the frontend
(3000) and optionally the gateway (8096).

---

## Table of Contents

1. [What Changed from v1](#1-what-changed-from-v1)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Initial Setup](#4-initial-setup)
5. [Deploy with podman-compose](#5-deploy-with-podman-compose)
6. [Alternative — Podman Pod (rootless, no Compose)](#6-alternative--podman-pod-rootless-no-compose)
7. [Environment Variables Reference](#7-environment-variables-reference)
8. [Verify the Deployment](#8-verify-the-deployment)
9. [Day-2 Operations](#9-day-2-operations)
10. [Security & Code Quality Pipeline](#10-security--code-quality-pipeline)
11. [Automated Pipeline Script](#11-automated-pipeline-script--security-pipelinesh)
    - [11.1 What it does](#111-what-it-does)
    - [11.2 Prerequisites](#112-prerequisites)
    - [11.3 Usage](#113-usage)
    - [11.4 Common run scenarios](#114-common-run-scenarios)
    - [11.5 Where it fits in the workflow](#115-where-it-fits-in-the-workflow)
    - [11.6 Reports](#116-reports)
    - [11.7 Terminal output](#117-terminal-output)
12. [Shutdown & Cleanup](#12-shutdown--cleanup)
    - [12.1 Stop — keep data](#121-stop--keep-data-restart-later)
    - [12.2 Full reset — wipe database](#122-full-reset--wipe-database)
    - [12.3 Full clean — remove images too](#123-full-clean--remove-images-too)
    - [12.4 Nuclear clean — prune entire Podman system](#124-nuclear-clean--prune-entire-podman-system)
    - [12.5 Pipeline artifact cleanup](#125-pipeline-artifact-cleanup)
    - [12.6 Pod teardown](#126-pod-teardown-section-6-users)
    - [12.7 Podman machine](#127-podman-machine-macos-only)

---

## 1. What Changed from v1

| Concern | v1 (bare-metal) | v2 (containers) |
|---|---|---|
| Runtime | systemd units on host JVM | Podman containers |
| MySQL | installed on host | `mysql:8.0` container |
| Frontend | React static files via Nginx | React dev-server container |
| Networking | `localhost:PORT` | container DNS (`auth-service`, `issue-service`, `mysql`) |
| Gateway profile | `local` (routes to localhost) | `prod` (routes to container hostnames) |
| Database | two databases (`authdb`, `issuedb`) | single shared database (`game_db`) |
| Secret management | env files on disk | `.env` file read by Compose |
| Orchestration | manual start order via systemd | `depends_on` + healthcheck in Compose |
| Build | Maven + npm on host | multi-stage Dockerfile (build inside container) |

---

## 2. Architecture

```
  Browser / External client
          │
          │ :3000
          ▼
  ┌─────────────────────────────────────────────────────┐
  │                  Podman Network                      │
  │               (issue-tracker-net)                    │
  │                                                      │
  │  ┌─────────────────────┐                            │
  │  │  frontend-service   │  container: issue-app-      │
  │  │  React dev server   │  frontend                   │
  │  │  port 3000          │  REACT_APP_API_BASE_URL=    │
  │  │                     │  http://localhost:8096       │
  │  └──────────┬──────────┘                            │
  │             │ browser calls → host:8096              │
  │             │                                        │
  │  ┌──────────▼──────────┐                            │
  │  │    api-gateway      │  container: issue-app-      │
  │  │  Spring Cloud GW    │  gateway                    │
  │  │  port 8096          │  profile: prod               │
  │  └────────┬──────┬─────┘                            │
  │           │      │                                   │
  │        :8097   :8098   (container-internal DNS)      │
  │           │      │                                   │
  │  ┌────────▼──┐  ┌▼──────────────┐                  │
  │  │auth-service│  │ issue-service │                  │
  │  │port 8097  │  │ port 8098     │                  │
  │  └─────┬─────┘  └──────┬────────┘                  │
  │        │               │                             │
  │        └───────┬────────┘                           │
  │                │ :3306                               │
  │        ┌───────▼────────┐                           │
  │        │    mysql:8.0   │  container: issue-app-    │
  │        │  game_db       │  mysql                    │
  │        │  volume:       │  persistent volume:       │
  │        │  mysql_data    │  mysql_data               │
  │        └────────────────┘                           │
  └─────────────────────────────────────────────────────┘
```

| Container | Image | Internal Port | Host Port |
|---|---|---|---|
| `issue-app-mysql` | `mysql:8.0` | 3306 | 3306 (optional) |
| `issue-app-auth` | built from `auth-service/Dockerfile` | 8097 | 8097 |
| `issue-app-issues` | built from `issue-service/Dockerfile` | 8098 | 8098 |
| `issue-app-gateway` | built from `api-gateway/Dockerfile` | 8096 | 8096 |
| `issue-app-frontend` | built from `frontend-service/Dockerfile` | 3000 | 3000 |

> **Container DNS:** The gateway's `prod` profile routes to `http://auth-service:8097`
> and `http://issue-service:8098`. These names resolve inside the Podman network
> automatically — no `/etc/hosts` changes needed.

---

## 3. Prerequisites

### 3.1 Install Podman

**Ubuntu / Debian:**
```bash
sudo apt update
sudo apt install -y podman
podman --version   # 4.x or higher recommended
```

**Fedora / RHEL / CentOS Stream:**
```bash
sudo dnf install -y podman
```

**macOS:**
```bash
brew install podman
podman machine init
podman machine start
```

### 3.2 Install podman-compose

`podman-compose` is a Python tool that reads Docker Compose files and translates them
into `podman run` calls. It is a drop-in replacement for `docker-compose`.

```bash
pip3 install podman-compose

# Verify
podman-compose --version   # 1.0.x or higher
```

> **Alternative:** If you prefer not to use `podman-compose`, see
> [Section 6](#6-alternative--podman-pod-rootless-no-compose) for the manual pod approach.

### 3.3 Enable lingering (rootless — recommended)

Rootless Podman containers stop when the user logs out unless lingering is enabled:

```bash
# Enable linger for the current user so containers survive logout
sudo loginctl enable-linger $USER
```

### 3.4 System requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| RAM | 4 GB | 8 GB |
| Disk | 15 GB free | 30 GB free |
| OS | Linux kernel 5.4+ | Ubuntu 22.04 LTS |

---

## 4. Initial Setup

### 4.1 Clone the v2 branch

```bash
git clone -b v2 https://github.com/amitactive2008/sample-spring-boot-application.git
cd sample-spring-boot-application
```

### 4.2 Create the `.env` file

```bash
cp .env.example .env
```

Open `.env` and set strong values for every variable:

```env
# ── MySQL ──────────────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=RootStr0ng@2024!
MYSQL_DATABASE=game_db
MYSQL_USER=game_admin
MYSQL_PASSWORD=Str0ngDB@2024!

# ── JWT (minimum 32 characters for HMAC-SHA256) ────────────────
JWT_SECRET=MyIssueTrackerJWTSecretKey2024!!

# ── Default admin user seeded on first startup ─────────────────
APP_ADMIN_EMAIL=admin@example.com
APP_ADMIN_PASSWORD=Admin@2024!
```

> **Never commit `.env` to git.** It is already listed in `.gitignore`. Verify with:
> ```bash
> git check-ignore -v .env   # should print: .gitignore:1:.env
> ```

---

## 5. Deploy with podman-compose

### 5.1 Build and start all containers

```bash
podman-compose up --build
```

What this does in order (controlled by `depends_on` + healthcheck):

1. Pulls `mysql:8.0` image, starts MySQL, waits for healthcheck to pass
2. Builds `auth-service` image (Maven inside Docker layer), starts container
3. Builds `issue-service` image, starts container
4. Builds `api-gateway` image, starts container
5. Builds `frontend-service` image (Node 20, `npm ci`), starts React dev server

> **First run takes 10–20 minutes** — Maven downloads all Spring Boot dependencies inside
> the build layer. Subsequent builds are fast due to Docker layer caching.

Run in detached (background) mode:
```bash
podman-compose up --build -d
```

### 5.2 Check container status

```bash
podman-compose ps
# or
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output:
```
NAMES                   STATUS                   PORTS
issue-app-frontend      Up 2 minutes             0.0.0.0:3000->3000/tcp
issue-app-gateway       Up 2 minutes             0.0.0.0:8096->8096/tcp
issue-app-auth          Up 3 minutes             0.0.0.0:8097->8097/tcp
issue-app-issues        Up 3 minutes             0.0.0.0:8098->8098/tcp
issue-app-mysql         Up 4 minutes (healthy)   0.0.0.0:3306->3306/tcp
```

### 5.3 Follow logs

```bash
# All containers
podman-compose logs -f

# Single service
podman logs -f issue-app-auth
podman logs -f issue-app-gateway
podman logs -f issue-app-mysql
```

### 5.4 Stop and remove containers

```bash
# Stop (keeps volumes/images)
podman-compose down

# Stop and remove the MySQL data volume (full reset)
podman-compose down -v

# Stop and remove images too
podman-compose down --rmi all -v
```

### 5.5 Rebuild a single service after code change

```bash
# Rebuild only auth-service without restarting everything
podman-compose build auth-service
podman-compose up -d --no-deps auth-service
```

---

## 6. Alternative — Podman Pod (rootless, no Compose)

A **Podman pod** groups containers together sharing the same network namespace — similar
to a Kubernetes pod. This approach has no `podman-compose` dependency and is fully
rootless.

### 6.1 Create the pod

```bash
podman pod create \
  --name issue-tracker \
  -p 3000:3000 \
  -p 8096:8096 \
  -p 8097:8097 \
  -p 8098:8098 \
  -p 3306:3306
```

### 6.2 Create a persistent volume for MySQL

```bash
podman volume create mysql_data
```

### 6.3 Start MySQL

```bash
podman run -d \
  --pod issue-tracker \
  --name issue-app-mysql \
  -e MYSQL_ROOT_PASSWORD=RootStr0ng@2024! \
  -e MYSQL_DATABASE=game_db \
  -e MYSQL_USER=game_admin \
  -e MYSQL_PASSWORD=Str0ngDB@2024! \
  -v mysql_data:/var/lib/mysql \
  mysql:8.0
```

Wait for MySQL to be healthy:
```bash
until podman exec issue-app-mysql mysqladmin ping -h localhost -uroot -pRootStr0ng@2024! --silent; do
  echo "Waiting for MySQL..."; sleep 3
done
```

### 6.4 Build service images

```bash
# Build all images from their Dockerfiles
podman build -t issue-auth-service    ./auth-service
podman build -t issue-issue-service   ./issue-service
podman build -t issue-api-gateway     ./api-gateway
podman build -t issue-frontend        ./frontend-service
```

### 6.5 Run Spring Boot services

```bash
# Auth Service
podman run -d \
  --pod issue-tracker \
  --name issue-app-auth \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://localhost:3306/game_db?useSSL=false&allowPublicKeyRetrieval=true" \
  -e SPRING_DATASOURCE_USERNAME=game_admin \
  -e SPRING_DATASOURCE_PASSWORD=Str0ngDB@2024! \
  -e JWT_SECRET=MyIssueTrackerJWTSecretKey2024!! \
  -e APP_ADMIN_EMAIL=admin@example.com \
  -e APP_ADMIN_PASSWORD=Admin@2024! \
  -e MAIL_ENABLED=false \
  -e SES_USERNAME=disabled \
  -e SES_PASSWORD=disabled \
  issue-auth-service

# Issue Service
podman run -d \
  --pod issue-tracker \
  --name issue-app-issues \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://localhost:3306/game_db?useSSL=false&allowPublicKeyRetrieval=true" \
  -e SPRING_DATASOURCE_USERNAME=game_admin \
  -e SPRING_DATASOURCE_PASSWORD=Str0ngDB@2024! \
  -e JWT_SECRET=MyIssueTrackerJWTSecretKey2024!! \
  issue-issue-service

# API Gateway
podman run -d \
  --pod issue-tracker \
  --name issue-app-gateway \
  -e SPRING_PROFILES_ACTIVE=prod \
  -e JWT_SECRET=MyIssueTrackerJWTSecretKey2024!! \
  -e CORS_ALLOWED_ORIGIN=http://localhost:3000 \
  issue-api-gateway
```

> **Note:** Inside a pod, all containers share `localhost`. The gateway `prod` profile
> routes to `http://auth-service:8097` (by container hostname). In a pod, use
> `http://localhost:8097` instead — or override the gateway's route URLs via environment
> variables, or use the `local` profile here.

### 6.6 Run the frontend

```bash
podman run -d \
  --pod issue-tracker \
  --name issue-app-frontend \
  -e REACT_APP_API_BASE_URL=http://localhost:8096 \
  issue-frontend
```

### 6.7 Generate a systemd unit to auto-start the pod on boot

```bash
# Generate systemd unit files for the pod and all containers
mkdir -p ~/.config/systemd/user
podman generate systemd --new --name issue-tracker \
  --files --restart-policy always

mv pod-issue-tracker.service      ~/.config/systemd/user/
mv container-issue-app-mysql.service  ~/.config/systemd/user/
mv container-issue-app-auth.service   ~/.config/systemd/user/
mv container-issue-app-issues.service ~/.config/systemd/user/
mv container-issue-app-gateway.service ~/.config/systemd/user/
mv container-issue-app-frontend.service ~/.config/systemd/user/

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now pod-issue-tracker.service
```

---

## 7. Environment Variables Reference

All values are read from `.env` by `podman-compose`. For the manual pod approach,
pass them with `-e KEY=VALUE` flags.

### 7.1 MySQL container

| Variable | Default | Description |
|---|---|---|
| `MYSQL_ROOT_PASSWORD` | `rootpassword` | Root password — change in production |
| `MYSQL_DATABASE` | `game_db` | Database created on first start |
| `MYSQL_USER` | `game_admin` | Application user |
| `MYSQL_PASSWORD` | `devpassword123` | Application user password |

### 7.2 auth-service

| Variable | Required | Description |
|---|---|---|
| `SPRING_DATASOURCE_URL` | yes | `jdbc:mysql://mysql:3306/game_db?...` (Compose) or `jdbc:mysql://localhost:3306/game_db?...` (pod) |
| `SPRING_DATASOURCE_USERNAME` | yes | Matches `MYSQL_USER` |
| `SPRING_DATASOURCE_PASSWORD` | yes | Matches `MYSQL_PASSWORD` |
| `JWT_SECRET` | yes | Min 32 chars — same across all three services |
| `APP_ADMIN_EMAIL` | yes | Seeded admin account |
| `APP_ADMIN_PASSWORD` | yes | Seeded admin password |
| `MAIL_ENABLED` | no | `false` disables email (AWS SES not needed locally) |
| `SES_USERNAME` | if mail | Set to `disabled` locally |
| `SES_PASSWORD` | if mail | Set to `disabled` locally |

### 7.3 issue-service

| Variable | Required | Description |
|---|---|---|
| `SPRING_DATASOURCE_URL` | yes | Same database as auth-service (`game_db`) |
| `SPRING_DATASOURCE_USERNAME` | yes | Matches `MYSQL_USER` |
| `SPRING_DATASOURCE_PASSWORD` | yes | Matches `MYSQL_PASSWORD` |
| `JWT_SECRET` | yes | Same value as auth-service |

### 7.4 api-gateway

| Variable | Required | Description |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | yes | `prod` — routes to container hostnames |
| `JWT_SECRET` | yes | Same value as auth-service and issue-service |
| `CORS_ALLOWED_ORIGIN` | no | Browser origin; defaults to `http://localhost:3000` |

### 7.5 frontend-service (build arg + runtime env)

| Variable | Description |
|---|---|
| `REACT_APP_API_BASE_URL` | URL the browser uses to call the API. Set to `http://localhost:8096` (gateway host port) |

> `REACT_APP_API_BASE_URL` is declared as an `ARG` in the Dockerfile so it is baked
> into the React build. It must point to an address the **browser** can reach
> (i.e., the host port, not the container-internal name).

---

## 8. Verify the Deployment

Replace `<HOST>` with the machine IP or `localhost`.

### 8.1 Container health

```bash
podman ps --format "table {{.Names}}\t{{.Status}}"
```

All containers must show `Up` and MySQL must show `(healthy)`.

### 8.2 Smoke test through the API

```bash
# 1. Register a user
curl -s -X POST http://<HOST>:8096/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"tester@example.com","password":"Test@1234"}'

# 2. Login — capture JWT
TOKEN=$(curl -s -X POST http://<HOST>:8096/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin@2024!"}' \
  | jq -r '.accessToken')

echo "Token: ${TOKEN:0:40}..."

# 3. Create an issue
curl -s -X POST http://<HOST>:8096/issues \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Container test issue","priority":"HIGH","severity":"MEDIUM"}'

# 4. List issues
curl -s http://<HOST>:8096/issues \
  -H "Authorization: Bearer $TOKEN" | jq '.content[].title'
```

### 8.3 Open the UI

Navigate to `http://<HOST>:3000` in a browser.

Login with `APP_ADMIN_EMAIL` / `APP_ADMIN_PASSWORD` from your `.env`.

---

## 9. Day-2 Operations

### View resource usage

```bash
podman stats --no-stream
```

### Access MySQL inside the container

```bash
podman exec -it issue-app-mysql \
  mysql -u game_admin -pStr0ngDB@2024! game_db
```

### Inspect container logs

```bash
podman logs --tail 100 issue-app-auth
podman logs --tail 100 issue-app-gateway
```

### Rebuild after a code change

```bash
# Rebuild a single service
podman-compose build auth-service
podman-compose up -d --no-deps auth-service

# Rebuild everything
podman-compose up --build -d
```

### Backup MySQL data volume

```bash
podman run --rm \
  -v mysql_data:/data \
  -v $(pwd):/backup \
  busybox tar czf /backup/mysql-backup-$(date +%F).tar.gz /data
```

### Scale: expose gateway via host Nginx

If you need a clean `:80` entry point (e.g., on a server), install Nginx on the host and
proxy to the gateway container:

```nginx
# /etc/nginx/sites-available/issue-tracker
server {
    listen 80;
    server_name _;

    location /auth/ {
        proxy_pass http://127.0.0.1:8096;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /issues {
        proxy_pass http://127.0.0.1:8096;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
    }
}
```

---

## 10. Security & Code Quality Pipeline

The containerized v2 deployment adds **two new layers** to the security pipeline from v1:

1. **Dockerfile linting** (Hadolint) — catches insecure Dockerfile patterns before image build
2. **Container image scanning** (Trivy) — scans the built images for OS-level and
   library-level CVEs, replacing the bare-metal NVD Check with a container-aware equivalent

All v1 tools (Gitleaks, Checkstyle, Semgrep, Maven Build, DAST, Lint, SonarQube,
Quality Gate, NVD Check) still apply — they now run inside the CI environment using the
same Dockerfiles, so they test the same artifact that goes to production.

```
Developer push / Pull Request
          │
          ▼
  ┌───────────────┐
  │  1. Gitleaks  │  ← Secrets in git history / .env accidentally committed?
  └───────┬───────┘
          │
          ▼
  ┌────────────────────┐
  │  2. Hadolint       │  ← NEW: Dockerfile best-practice and security lint
  └────────┬───────────┘
          │
          ▼
  ┌────────────────┐
  │ 3. Checkstyle  │  ← Java source code style enforcement
  └───────┬────────┘
          │
          ▼
  ┌──────────────┐
  │  4. Semgrep  │  ← SAST: Java + JS security anti-patterns
  └──────┬───────┘
          │
          ▼
  ┌──────────────────────────────────────┐
  │  5. ./mvnw clean package -DskipTests │  ← Compile + package inside CI
  └──────────────────┬───────────────────┘
          │
          ▼
  ┌──────────────────┐
  │  6. NVD Check    │  ← OWASP Dependency-Check on JARs + npm audit
  └──────┬───────────┘
          │
          ▼
  ┌──────────────────┐
  │  7. Lint         │  ← ESLint (React) + SpotBugs (Java)
  └──────┬───────────┘
          │
          ▼
  ┌──────────────────────────┐
  │  8. podman build (all)   │  ← Build container images from Dockerfiles
  └──────────┬───────────────┘
          │
          ▼
  ┌──────────────────┐
  │  9. Trivy        │  ← NEW: Scan images for OS + lib CVEs before push
  └──────┬───────────┘
          │
          ▼
  ┌─────────────┐
  │ 10. SonarQube│  ← Deep quality + security analysis
  └──────┬──────┘
          │
          ▼
  ┌────────────────┐
  │ 11. Quality Gate│  ← Hard pass/fail: blocks merge if thresholds not met
  └──────┬─────────┘
          │
       MERGE + push images to registry
          │
     Deploy containers to staging
          │
          ▼
  ┌────────────────────┐
  │  12. DAST Audit    │  ← OWASP ZAP against running containers on staging
  └────────────────────┘
          │
     Promote to production
```

---

### 10.1 Gitleaks — Secret Scanning

**What it is:**
Scans git commits and history for accidentally committed secrets — passwords, API keys,
JWT secrets, connection strings.

**Why it matters for v2:**
The `.env` file now contains the MySQL root password, application DB password, and JWT
secret in plain text. Gitleaks prevents this file from ever reaching the remote. It also
catches secrets hardcoded in Dockerfiles (e.g., `ENV JWT_SECRET=hardcoded`).

**How to apply:**

```bash
# Install
brew install gitleaks           # macOS
pip install pre-commit && pre-commit install   # as a commit hook

# Scan the full repo
gitleaks detect --source . --verbose

# Scan only new commits (PR mode)
gitleaks detect --source . --log-opts="origin/main..HEAD"
```

Create `.pre-commit-config.yaml`:
```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
```

Create `.gitleaks.toml` to suppress dummy values in `.env.example`:
```toml
[allowlist]
regexes = [
  "rootpassword",
  "devpassword123",
  "local-dev-jwt-secret-key-32bytes!!",
  "disabled"
]
```

Ensure `.env` is gitignored:
```bash
echo ".env" >> .gitignore
git check-ignore -v .env   # must print a match
```

---

### 10.2 Hadolint — Dockerfile Linting

**What it is:**
Hadolint (Haskell Dockerfile Linter) statically analyses each `Dockerfile` against a
ruleset of best practices and security guidelines. It catches patterns like running as
`root`, using `latest` tags (unpinned images), unnecessary package installs, and missing
`HEALTHCHECK` instructions.

**SDLC value:**
Container images are immutable artifacts — a bad Dockerfile creates a bad image that is
then deployed everywhere. Hadolint catches these issues at pull-request time, before
any image is built, at zero cost.

**Specific findings it will raise in this project's Dockerfiles:**

| Rule | Dockerfile location | Issue |
|---|---|---|
| DL3008 | all Java Dockerfiles | No `apt-get` pin (N/A here, but base image choice matters) |
| DL3007 | `frontend-service/Dockerfile` | `FROM node:20` — unpinned; use `node:20-alpine` |
| DL3025 | all Dockerfiles | Use `CMD ["executable"]` JSON array form (already done — pass) |
| SC2086 | any shell forms | Unquoted variables in `RUN` |
| DL3002 | all Dockerfiles | Last `USER` should not be root — none of the Dockerfiles set a non-root user |

**How to apply:**

Install:
```bash
# macOS
brew install hadolint

# Linux
wget -O /usr/local/bin/hadolint \
  https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64
chmod +x /usr/local/bin/hadolint
```

Lint all Dockerfiles:
```bash
hadolint auth-service/Dockerfile
hadolint issue-service/Dockerfile
hadolint api-gateway/Dockerfile
hadolint frontend-service/Dockerfile
```

Run all in one command (CI):
```bash
find . -name "Dockerfile" | xargs hadolint --failure-threshold warning
```

**Recommended Dockerfile improvements for this project** —
add a non-root user to each Java service Dockerfile:

```dockerfile
# auth-service/Dockerfile (hardened)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -DskipTests package -B --no-transfer-progress

FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
# Run as non-root
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
COPY --from=build /app/target/*.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser
EXPOSE 8097
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:8097/actuator/health || exit 1
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Apply the same pattern to `issue-service/Dockerfile` (port 8098) and
`api-gateway/Dockerfile` (port 8096).

---

### 10.3 Checkstyle — Java Code Style Enforcement

Same as v1. Add the Maven plugin to each Java service's `pom.xml` bound to the
`validate` phase with a `checkstyle.xml` ruleset. The build step inside the Dockerfile
(`RUN mvn -DskipTests package`) will automatically run Checkstyle since it is bound to
`validate`, which runs before `compile`.

```bash
# Run locally before building the image
cd auth-service  && ./mvnw checkstyle:check && cd ..
cd issue-service && ./mvnw checkstyle:check && cd ..
cd api-gateway   && ./mvnw checkstyle:check && cd ..
```

See v1 README Section 12.2 for the full `pom.xml` plugin block and `checkstyle.xml`.

---

### 10.4 Semgrep — SAST

Same rules as v1, with the addition of a Dockerfile-specific ruleset:

```bash
semgrep \
  --config p/spring-security \
  --config p/java \
  --config p/owasp-top-ten \
  --config p/javascript \
  --config p/react \
  --config p/dockerfile \    # NEW: catches ADD instead of COPY, curl | bash, etc.
  --error \
  .
```

Notable Dockerfile rule catches: `p/dockerfile` flags `curl | bash` patterns, `ADD`
instead of `COPY`, secrets passed via `ENV` in Dockerfiles, and images running as root.

---

### 10.5 Maven Build — `./mvnw clean package -DskipTests -B`

In v2 the build happens **inside the Dockerfile** (`RUN mvn -DskipTests package`).
However, running it separately in CI before the Docker build serves two purposes:

1. Fast failure — if the code does not compile, fail in seconds without wasting time
   building a Docker image layer
2. Produces JARs on the CI host for OWASP Dependency-Check to scan (NVD Check step)

```bash
# Run on CI host before docker/podman build
cd auth-service  && ./mvnw clean package -DskipTests -B && cd ..
cd issue-service && ./mvnw clean package -DskipTests -B && cd ..
cd api-gateway   && ./mvnw clean package -DskipTests -B && cd ..
```

---

### 10.6 NVD Check — Dependency Vulnerability Scanning

Same as v1 — OWASP Dependency-Check scans JAR files and `npm audit` scans Node packages.
Because the Maven build now also runs inside the Docker layer, run the check against the
host-side JARs produced by the CI build step (Section 10.5).

```bash
export NVD_API_KEY=<your-nvd-api-key>

# Scan all three services
cd auth-service  && ./mvnw dependency-check:check && cd ..
cd issue-service && ./mvnw dependency-check:check && cd ..
cd api-gateway   && ./mvnw dependency-check:check && cd ..

# Frontend npm audit
cd frontend-service && npm audit --audit-level=high && cd ..
```

See v1 README Section 12.9 for the full Maven plugin block, NVD API key setup, and
suppression file template.

---

### 10.7 Lint — ESLint + SpotBugs

Same as v1. Add `"lint": "eslint src --ext .js,.jsx --max-warnings 0"` to
`frontend-service/package.json` scripts. Add SpotBugs Maven plugin to Java service
`pom.xml` files. Run before the `podman build` step so image build is never attempted
on linting failures.

```bash
cd frontend-service && npm run lint && cd ..
cd auth-service     && ./mvnw spotbugs:check && cd ..
cd issue-service    && ./mvnw spotbugs:check && cd ..
```

---

### 10.8 Podman Build — Container Image Build

After all source-level checks pass, build the container images:

```bash
podman build -t issue-tracker/auth-service:ci    ./auth-service
podman build -t issue-tracker/issue-service:ci   ./issue-service
podman build -t issue-tracker/api-gateway:ci     ./api-gateway
podman build \
  --build-arg REACT_APP_API_BASE_URL=http://localhost:8096 \
  -t issue-tracker/frontend:ci \
  ./frontend-service
```

Tag for your container registry after scanning:
```bash
podman tag issue-tracker/auth-service:ci  registry.example.com/issue-tracker/auth-service:$(git rev-parse --short HEAD)
```

---

### 10.9 Trivy — Image Scan & Config Scan

**What it is:**
Trivy (by Aqua Security) is an all-in-one security scanner that covers two distinct
scanning modes used in this project:

| Mode | Command | What it scans |
|---|---|---|
| **Image scan** | `trivy image` | Built container images — OS packages, language libraries, secrets baked into layers |
| **Config scan** | `trivy config` | Source files before build — Dockerfiles, `docker-compose.yml` — for misconfigurations |

Both modes run as separate, sequential CI steps. Config scan runs **before** `podman build`
(no image needed); image scan runs **after** `podman build` (needs the built image).

```
  Dockerfile / docker-compose.yml
          │
          ▼
  ┌───────────────────┐
  │ trivy config      │  ← Pre-build: finds Dockerfile and Compose misconfigs
  └────────┬──────────┘
           │  (must pass before build proceeds)
           ▼
  ┌───────────────────┐
  │  podman build     │  ← Builds the container image
  └────────┬──────────┘
           │
           ▼
  ┌───────────────────┐
  │ trivy image       │  ← Post-build: scans the image layers for CVEs + secrets
  └───────────────────┘
```

---

#### Install Trivy

```bash
# macOS
brew install trivy

# Linux (official install script)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b /usr/local/bin

# Verify
trivy --version   # Trivy version 0.5x.x
```

---

#### A. `trivy image` — Container Image Scanning

`trivy image` pulls apart every layer of a built container image and inspects:

- **OS packages** — `dpkg` / `rpm` packages in the base image
  (e.g., `libssl`, `libc6`, `curl` inside `eclipse-temurin:17-jre-jammy`)
- **Language libraries** — JARs on the classpath, `node_modules` packages,
  Python wheels, Go binaries embedded in the image
- **Secrets** — API keys, private keys, JWT secrets, passwords accidentally
  copied into the image via `COPY . .` or left in build layers
- **License compliance** — flags GPL/AGPL dependencies if license policy is set

##### A.1 Scan a single image

```bash
trivy image issue-tracker/auth-service:ci
```

This prints a table like:

```
issue-tracker/auth-service:ci (debian 12.5)
============================================
Total: 4 (HIGH: 3, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬───────────────┬──────────────────┬──────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ Inst. Version │   Fix Version    │                  Title                   │
├──────────────┼────────────────┼──────────┼───────────────┼──────────────────┼──────────────────────────────────────────┤
│ libssl3      │ CVE-2024-XXXX  │ CRITICAL │ 3.0.2-0ubuntu │ 3.0.2-0ubuntu1.1 │ OpenSSL: buffer overflow in ... [details]│
│ ...          │ ...            │ ...      │ ...           │ ...              │ ...                                      │
└──────────────┴────────────────┴──────────┴───────────────┴──────────────────┴──────────────────────────────────────────┘
```

##### A.2 Scan all four service images (CI-ready loop)

```bash
IMAGES=(
  "issue-tracker/auth-service:ci"
  "issue-tracker/issue-service:ci"
  "issue-tracker/api-gateway:ci"
  "issue-tracker/frontend:ci"
)

for IMAGE in "${IMAGES[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  trivy image → ${IMAGE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  trivy image \
    --exit-code 1 \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --no-progress \
    "${IMAGE}"
done
```

##### A.3 Flags reference

| Flag | Value | Meaning |
|---|---|---|
| `--exit-code 1` | — | Exit non-zero if findings at or above `--severity`; blocks CI |
| `--severity` | `HIGH,CRITICAL` | Only HIGH and CRITICAL block the pipeline; MEDIUM/LOW are reported |
| `--ignore-unfixed` | — | Skip CVEs where the vendor has not yet released a fix |
| `--no-progress` | — | Suppress the download progress bar (cleaner CI logs) |
| `--scanners` | `vuln,secret` | Explicitly set what to scan (default includes `vuln`) |
| `--format` | `table` / `json` / `sarif` / `cyclonedx` | Output format |
| `--output` | `report.json` | Write report to file instead of stdout |
| `--cache-dir` | `/path/to/cache` | Reuse downloaded vulnerability DB across runs (speeds up CI) |
| `--db-repository` | `ghcr.io/aquasecurity/trivy-db` | Mirror to use when the default is rate-limited |
| `--timeout` | `10m` | Increase for large images |

##### A.4 Secret scanning inside image layers

Trivy also detects secrets that were accidentally baked into image layers — for example,
if a developer ran `COPY .env .` in a Dockerfile.

```bash
# Enable secret scanning explicitly
trivy image \
  --scanners vuln,secret \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  issue-tracker/auth-service:ci
```

If a `.env` file was ever `COPY`-ed into a build stage, Trivy will flag:
```
MEDIUM  secret  General  secret/token  aws-access-token  Found AWS access token
HIGH    secret  General  secret/token  jwt               Found JWT token
```

This is why the auth-service and issue-service Dockerfiles must never copy `.env`:

```dockerfile
# WRONG — copies .env into the image layer
COPY . .

# CORRECT — copy only what is needed
COPY pom.xml .
COPY src ./src
```

##### A.5 Output formats

**JSON** (for CI artifact upload or pipeline parsing):
```bash
trivy image \
  --format json \
  --output trivy-auth-service.json \
  issue-tracker/auth-service:ci
```

**SARIF** (for GitHub Advanced Security / code scanning upload):
```bash
trivy image \
  --format sarif \
  --output trivy-auth-service.sarif \
  issue-tracker/auth-service:ci
```

Upload SARIF to GitHub (in Actions workflow):
```yaml
- name: Upload Trivy SARIF to GitHub Security
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-auth-service.sarif
    category: trivy-auth-service
```

**HTML** (human-readable report for review):
```bash
trivy image \
  --format template \
  --template "@contrib/html.tpl" \
  --output trivy-auth-service.html \
  issue-tracker/auth-service:ci
```

**CycloneDX SBOM** (Software Bill of Materials — for supply-chain compliance):
```bash
trivy image \
  --format cyclonedx \
  --output sbom-auth-service.cdx.json \
  issue-tracker/auth-service:ci
```

##### A.6 Scanning with Podman (no Docker daemon)

Trivy needs to access image storage. With Podman (daemonless), use one of two methods:

**Method 1 — Podman REST API socket:**
```bash
# Start the Podman socket
systemctl --user start podman.socket

# Point Trivy to the Podman socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock

# Now trivy image works exactly as with Docker
trivy image issue-tracker/auth-service:ci
```

**Method 2 — Export image as OCI tar (no socket required):**
```bash
# Export image to a tar archive
podman save --format oci-archive \
  issue-tracker/auth-service:ci \
  -o auth-service.tar

# Scan the tar archive directly
trivy image \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --input auth-service.tar

# Clean up
rm auth-service.tar
```

> Method 2 works in any CI environment including GitHub Actions runners that have
> Podman but no socket configured.

##### A.7 Caching the vulnerability database in CI

The Trivy DB is downloaded on every fresh runner. Cache it between runs to cut
`trivy image` startup time from ~90 seconds to ~2 seconds:

```yaml
# GitHub Actions — cache Trivy DB between runs
- name: Cache Trivy vulnerability database
  uses: actions/cache@v4
  with:
    path: ~/.cache/trivy
    key: trivy-db-${{ github.run_id }}
    restore-keys: trivy-db-

- name: Update Trivy DB
  run: trivy image --download-db-only --no-progress

- name: Trivy image scan — auth-service
  run: |
    trivy image \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --no-progress \
      --cache-dir ~/.cache/trivy \
      issue-tracker/auth-service:ci
```

##### A.8 Suppressing accepted findings (`.trivyignore`)

For CVEs that have been reviewed and accepted (e.g., no fix available, or only affects a
feature not used), add them to `.trivyignore` at the repo root with a mandatory comment:

```bash
# .trivyignore
# Format: CVE-ID  (one per line, comments with #)

# CVE-2023-XXXXX: Affects H2 console mode only — H2 is test-scope only, not in prod image
# Accepted: 2024-08-01 | Review by: 2025-02-01
CVE-2023-XXXXX
```

> Every suppressed CVE must have a comment with the justification and a review-by date.
> Trivy does not enforce expiry automatically — add a calendar reminder.

---

#### B. `trivy config` — Misconfiguration Scanning

`trivy config` scans **source files** for misconfigurations before any image is built.
It does not need a running container or a built image — it reads the raw text of
Dockerfiles, Compose files, and IaC configs and applies a library of security rules.

Scanner targets for this project:

| File | Checks applied |
|---|---|
| `*/Dockerfile` | Dockerfile security rules (`DS` category) |
| `docker-compose.yml` | Compose-specific rules (privileged mode, host networking, missing resource limits) |

##### B.1 Scan all Dockerfiles individually

```bash
# Each returns findings specific to that service
trivy config auth-service/Dockerfile
trivy config issue-service/Dockerfile
trivy config api-gateway/Dockerfile
trivy config frontend-service/Dockerfile
```

##### B.2 Scan the entire project directory at once

```bash
# Trivy auto-discovers all Dockerfiles and docker-compose.yml
trivy config \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  .
```

##### B.3 Misconfiguration rules and what they flag in this project

Trivy will raise the following findings against the existing v2 Dockerfiles and
`docker-compose.yml`:

**Dockerfile findings:**

| Check ID | Severity | File | Finding | Fix |
|---|---|---|---|---|
| `DS002` | HIGH | All Java Dockerfiles | No `USER` instruction — process runs as root inside container | Add `RUN adduser --system appuser && USER appuser` |
| `DS026` | LOW | All Dockerfiles | No `HEALTHCHECK` instruction | Add `HEALTHCHECK CMD curl -f http://localhost:<PORT>/actuator/health` |
| `DS013` | LOW | `frontend-service/Dockerfile` | `RUN npm ci` runs as root | Add non-root user before `npm ci` |
| `DS014` | LOW | All Java Dockerfiles | Base image `eclipse-temurin:17-jre` is not pinned to a digest | Use `eclipse-temurin:17-jre-jammy@sha256:<digest>` |
| `DS025` | LOW | All Dockerfiles | `latest`-equivalent tags used (no digest pinning) | Pin with `@sha256:...` |

**docker-compose.yml findings:**

| Check ID | Severity | Finding | Fix |
|---|---|---|---|
| `KSV011` | LOW | No CPU limits set on any service | Add `deploy.resources.limits.cpus` |
| `KSV012` | LOW | No memory limits set | Add `deploy.resources.limits.memory` |
| `KSV014` | LOW | Root filesystem is writable in all containers | Add `read_only: true` where possible |
| `KSV021` | LOW | No `security_opt: no-new-privileges` | Add `security_opt: ["no-new-privileges:true"]` |

##### B.4 Output formats for config scan

```bash
# Table (default — human readable)
trivy config .

# JSON (machine readable — for CI parsing)
trivy config --format json --output trivy-config-report.json .

# SARIF (for GitHub Security code scanning)
trivy config --format sarif --output trivy-config.sarif .
```

Upload SARIF from config scan:
```yaml
- name: Upload config scan SARIF
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-config.sarif
    category: trivy-config
```

##### B.5 Skip specific checks

If a rule does not apply to your environment, skip it explicitly (with a comment in the
pipeline explaining why):

```bash
# Skip HEALTHCHECK and digest-pinning checks
# DS026: HEALTHCHECK — managed by Compose healthcheck, not Dockerfile
# DS014: digest pinning — not required for internal dev images
trivy config \
  --skip-check-update \
  --misconfiguration-scanners dockerfile \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --skip-checks DS026,DS014 \
  .
```

Document every skipped check in a comment — it is an accepted risk, not an absence of risk.

##### B.6 Hardened `docker-compose.yml` addressing Trivy findings

Add the following to each service in `docker-compose.yml` to resolve the LOW-severity
findings:

```yaml
services:

  auth-service:
    # ... existing config ...
    security_opt:
      - no-new-privileges:true     # KSV021
    read_only: true                # KSV014 — container FS is read-only
    tmpfs:
      - /tmp                       # Spring Boot needs /tmp for temp files
    deploy:
      resources:
        limits:
          cpus: '1.0'              # KSV011
          memory: 512M             # KSV012

  issue-service:
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M

  api-gateway:
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M

  frontend-service:
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

  mysql:
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
```

---

#### C. Combined Trivy CI Step Reference

The two Trivy steps are separate jobs in CI — config scan before build, image scan after:

```yaml
# ── Trivy Config Scan (pre-build, no image needed) ──────────────────────────
- name: Trivy — config scan (Dockerfiles + docker-compose.yml)
  run: |
    trivy config \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --format sarif \
      --output trivy-config.sarif \
      --no-progress \
      .

- name: Upload config scan SARIF
  uses: github/codeql-action/upload-sarif@v3
  if: always()    # upload even if the step above failed
  with:
    sarif_file: trivy-config.sarif
    category: trivy-config

# ── podman build all images ──────────────────────────────────────────────────
- name: Build container images
  run: |
    podman build -t issue-tracker/auth-service:ci    ./auth-service
    podman build -t issue-tracker/issue-service:ci   ./issue-service
    podman build -t issue-tracker/api-gateway:ci     ./api-gateway
    podman build \
      --build-arg REACT_APP_API_BASE_URL=http://localhost:8096 \
      -t issue-tracker/frontend:ci ./frontend-service

# ── Trivy Image Scan (post-build) ────────────────────────────────────────────
- name: Cache Trivy DB
  uses: actions/cache@v4
  with:
    path: ~/.cache/trivy
    key: trivy-db-${{ github.run_id }}
    restore-keys: trivy-db-

- name: Download Trivy DB
  run: trivy image --download-db-only --no-progress --cache-dir ~/.cache/trivy

- name: Trivy image — auth-service
  run: |
    podman save --format oci-archive issue-tracker/auth-service:ci -o auth-service.tar
    trivy image \
      --input auth-service.tar \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --scanners vuln,secret \
      --format sarif \
      --output trivy-image-auth.sarif \
      --cache-dir ~/.cache/trivy \
      --no-progress
    rm auth-service.tar

- name: Trivy image — issue-service
  run: |
    podman save --format oci-archive issue-tracker/issue-service:ci -o issue-service.tar
    trivy image \
      --input issue-service.tar \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --scanners vuln,secret \
      --format sarif \
      --output trivy-image-issues.sarif \
      --cache-dir ~/.cache/trivy \
      --no-progress
    rm issue-service.tar

- name: Trivy image — api-gateway
  run: |
    podman save --format oci-archive issue-tracker/api-gateway:ci -o api-gateway.tar
    trivy image \
      --input api-gateway.tar \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --scanners vuln,secret \
      --format sarif \
      --output trivy-image-gateway.sarif \
      --cache-dir ~/.cache/trivy \
      --no-progress
    rm api-gateway.tar

- name: Trivy image — frontend
  run: |
    podman save --format oci-archive issue-tracker/frontend:ci -o frontend.tar
    trivy image \
      --input frontend.tar \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --scanners vuln,secret \
      --format sarif \
      --output trivy-image-frontend.sarif \
      --cache-dir ~/.cache/trivy \
      --no-progress
    rm frontend.tar

- name: Upload all Trivy image SARIFs
  uses: github/codeql-action/upload-sarif@v3
  if: always()
  with:
    sarif_file: trivy-image-auth.sarif
    category: trivy-image-auth

# repeat upload step for issues / gateway / frontend SARIFs
```

---

#### D. Trivy Quick-Reference Summary

| Sub-command | Trigger | Blocks build? | Key flags |
|---|---|---|---|
| `trivy config` | Pre-build (Dockerfile + Compose exist) | Yes — HIGH/CRIT misconfigs | `--exit-code 1 --severity HIGH,CRITICAL --format sarif` |
| `trivy image` | Post-build (image exists in Podman) | Yes — HIGH/CRIT CVEs | `--exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln,secret` |

---

### 10.10 SonarQube — Code Quality & Security Analysis

Same configuration as v1. Run the Maven Sonar analysis on the host-side build:

```bash
cd auth-service
./mvnw sonar:sonar \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login=$SONAR_TOKEN \
  -Dsonar.projectKey=issue-tracker-auth-v2
```

For v2, also enable SonarQube's **Docker/container analysis** so it understands the
containerized build context. In the SonarQube project settings, enable
"Docker" under the analysis scope.

See v1 README Section 12.7 for Docker-based SonarQube server setup, `sonar-project.properties`,
and frontend analysis commands.

---

### 10.11 Quality Gate

Same conditions as v1. The Quality Gate evaluates results from SonarQube and blocks
merge if thresholds are not met:

```bash
STATUS=$(curl -s -u $SONAR_TOKEN: \
  "http://localhost:9000/api/qualitygates/project_status?projectKey=issue-tracker-auth-v2" \
  | jq -r '.projectStatus.status')
[ "$STATUS" = "OK" ] || { echo "Quality Gate FAILED"; exit 1; }
```

See v1 README Section 12.8 for the full conditions table.

---

### 10.12 DAST Audit — Dynamic Application Security Testing

In v2, DAST runs against the **containerized staging stack** — all five containers
running together — after code merges and images are deployed.

```bash
# Ensure staging containers are up
podman-compose up -d

# Wait for health
until curl -s http://localhost:8096/actuator/health | grep -q '"status":"UP"'; do
  sleep 5
done

# Get a token for authenticated DAST
TOKEN=$(curl -s -X POST http://localhost:8096/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin@2024!"}' \
  | jq -r '.accessToken')

# Baseline scan (safe, passive)
docker run --rm --network host ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
  -t http://localhost:3000 \
  -r zap-report.html

# API scan against the gateway
docker run --rm --network host ghcr.io/zaproxy/zaproxy:stable zap-api-scan.py \
  -t http://localhost:8096 \
  -f openapi \
  -r zap-api-report.html
```

---

### Security Pipeline — Quick Reference (v2)

| # | Tool | Stage | Scope | Blocks? |
|---|---|---|---|---|
| 1 | **Gitleaks** | Pre-commit / CI | Git history, `.env` leak detection | Yes |
| 2 | **Hadolint** | CI — pre-build | All four Dockerfiles | Yes |
| 3 | **Checkstyle** | CI — validate | Java source style (3 services) | Yes |
| 4 | **Semgrep** | CI — SAST | Java + JS/React + Dockerfile patterns | Yes |
| 5 | **Maven Build** | CI — compile | Produce JARs for subsequent scans | Yes |
| 6 | **NVD Check** | CI — SCA | JAR deps (OWASP) + npm audit | Yes (CVSS ≥ 7) |
| 7 | **Lint** | CI | ESLint (React) + SpotBugs (Java) | Yes |
| 8 | **Podman Build** | CI — image build | Build all 4 container images | Yes |
| 9 | **Trivy** | CI — image scan | OS packages + libs inside images | Yes (HIGH/CRIT) |
| 10 | **SonarQube** | CI — analysis | All services + frontend | Yes |
| 11 | **Quality Gate** | CI — gate | SonarQube thresholds | Yes |
| 12 | **DAST Audit** | Post-deploy staging | Running containers over HTTP | Blocks promotion |

---

### Full CI Pipeline — GitHub Actions Skeleton (v2)

```yaml
name: CI Pipeline — v2 (Podman)

on: [push, pull_request]

env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/${{ github.repository_owner }}/issue-tracker

jobs:
  pipeline:
    runs-on: ubuntu-latest
    steps:

      # ── Checkout ────────────────────────────────────────────────────────
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ── 1. Gitleaks ─────────────────────────────────────────────────────
      - name: Gitleaks — secret scan
        uses: gitleaks/gitleaks-action@v2

      # ── 2. Hadolint — Dockerfile lint ───────────────────────────────────
      - name: Hadolint — auth-service Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: auth-service/Dockerfile
          failure-threshold: warning
      - name: Hadolint — issue-service Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: issue-service/Dockerfile
          failure-threshold: warning
      - name: Hadolint — api-gateway Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: api-gateway/Dockerfile
          failure-threshold: warning
      - name: Hadolint — frontend Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: frontend-service/Dockerfile
          failure-threshold: warning

      # ── 3 & 5. Checkstyle + Maven Build ────────────────────────────────
      - uses: actions/setup-java@v4
        with: { java-version: '17', distribution: 'temurin' }
      - name: Build auth-service
        run: ./mvnw clean package -DskipTests -B
        working-directory: auth-service
      - name: Build issue-service
        run: ./mvnw clean package -DskipTests -B
        working-directory: issue-service
      - name: Build api-gateway
        run: ./mvnw clean package -DskipTests -B
        working-directory: api-gateway

      # ── 4. Semgrep ──────────────────────────────────────────────────────
      - name: Semgrep SAST
        run: |
          pip install semgrep
          semgrep --config p/spring-security --config p/java \
                  --config p/owasp-top-ten --config p/javascript \
                  --config p/react --config p/dockerfile \
                  --error .

      # ── 6. NVD Check ────────────────────────────────────────────────────
      - name: NVD Check — auth-service
        run: ./mvnw dependency-check:check
        working-directory: auth-service
        env:
          NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
      - name: NVD Check — issue-service
        run: ./mvnw dependency-check:check
        working-directory: issue-service
        env:
          NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
      - name: NVD Check — api-gateway
        run: ./mvnw dependency-check:check
        working-directory: api-gateway
        env:
          NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
      - uses: actions/setup-node@v4
        with: { node-version: '18' }
      - run: npm ci
        working-directory: frontend-service
      - name: npm audit
        run: npm audit --audit-level=high
        working-directory: frontend-service

      # ── 7. Lint ─────────────────────────────────────────────────────────
      - name: ESLint
        run: npm run lint
        working-directory: frontend-service
      - name: SpotBugs — auth-service
        run: ./mvnw spotbugs:check
        working-directory: auth-service
      - name: SpotBugs — issue-service
        run: ./mvnw spotbugs:check
        working-directory: issue-service

      # ── 8. Podman Build ─────────────────────────────────────────────────
      - name: Install Podman
        run: sudo apt-get install -y podman
      - name: Build container images
        run: |
          podman build -t $IMAGE_PREFIX/auth-service:ci    ./auth-service
          podman build -t $IMAGE_PREFIX/issue-service:ci   ./issue-service
          podman build -t $IMAGE_PREFIX/api-gateway:ci     ./api-gateway
          podman build \
            --build-arg REACT_APP_API_BASE_URL=http://localhost:8096 \
            -t $IMAGE_PREFIX/frontend:ci \
            ./frontend-service

      # ── 9. Trivy — image scanning ───────────────────────────────────────
      - name: Trivy — scan auth-service image
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.IMAGE_PREFIX }}/auth-service:ci
          exit-code: '1'
          severity: HIGH,CRITICAL
          ignore-unfixed: true
      - name: Trivy — scan issue-service image
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.IMAGE_PREFIX }}/issue-service:ci
          exit-code: '1'
          severity: HIGH,CRITICAL
          ignore-unfixed: true
      - name: Trivy — scan api-gateway image
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.IMAGE_PREFIX }}/api-gateway:ci
          exit-code: '1'
          severity: HIGH,CRITICAL
          ignore-unfixed: true
      - name: Trivy — scan frontend image
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.IMAGE_PREFIX }}/frontend:ci
          exit-code: '1'
          severity: HIGH,CRITICAL
          ignore-unfixed: true

      # ── 10 & 11. SonarQube + Quality Gate ──────────────────────────────
      - name: SonarQube analysis
        run: |
          ./mvnw sonar:sonar \
            -Dsonar.host.url=${{ secrets.SONAR_HOST }} \
            -Dsonar.login=${{ secrets.SONAR_TOKEN }} \
            -Dsonar.projectKey=issue-tracker-auth-v2
        working-directory: auth-service
      - name: Quality Gate check
        run: |
          STATUS=$(curl -s -u ${{ secrets.SONAR_TOKEN }}: \
            "${{ secrets.SONAR_HOST }}/api/qualitygates/project_status?projectKey=issue-tracker-auth-v2" \
            | jq -r '.projectStatus.status')
          echo "Quality Gate: $STATUS"
          [ "$STATUS" = "OK" ] || exit 1

      # ── Push images (only on merge to main) ─────────────────────────────
      - name: Push images to registry
        if: github.ref == 'refs/heads/main'
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | podman login ghcr.io -u ${{ github.actor }} --password-stdin
          podman push $IMAGE_PREFIX/auth-service:ci
          podman push $IMAGE_PREFIX/issue-service:ci
          podman push $IMAGE_PREFIX/api-gateway:ci
          podman push $IMAGE_PREFIX/frontend:ci

  # ── 12. DAST — runs after staging deploy ──────────────────────────────
  dast:
    needs: pipeline
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - name: OWASP ZAP Baseline Scan
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: ${{ secrets.STAGING_URL }}
          fail_action: true
```

---

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `NVD_API_KEY` | Free API key from https://nvd.nist.gov/developers/request-an-api-key |
| `SONAR_HOST` | SonarQube server URL (e.g., `http://sonarqube.internal:9000`) |
| `SONAR_TOKEN` | SonarQube analysis token |
| `STAGING_URL` | Full URL of the staging deployment for DAST (e.g., `http://staging.internal:3000`) |

---

## 11. Automated Pipeline Script — `security-pipeline.sh`

`security-pipeline.sh` at the repository root runs the complete 12-step pipeline from
Section 10 with a single command. It is designed to run on the **developer's workstation
or a CI agent** — not inside a container. It installs every missing tool automatically
and writes timestamped reports to `/tmp/pipeline-reports/`.

---

### 11.1 What it does

The script orchestrates all 12 checks in the correct order and handles step dependencies
automatically — if Maven Build fails, the steps that require compiled artifacts (NVD Check,
Lint, SonarQube) are skipped rather than producing misleading results.

```
10.1  Gitleaks     ──► 10.2  Hadolint   ──► 10.3  Checkstyle ──► 10.4  Semgrep
                                                                         │
                    ┌────────────────────────────────────────────────────┘
                    ▼
               10.5  Maven Build
               ├──► 10.6  NVD Check          (skipped if build fails)
               ├──► 10.7  Lint               (skipped if build fails)
               └──► 10.8  Podman Build
                         └──► 10.9  Trivy    (skipped if images missing)
                                    │
               ┌────────────────────┘
               ▼
          10.10  SonarQube ──► 10.11  Quality Gate
                                         │
                                      MERGE
                                         │
                                    Deploy to staging
                                         │
                                         ▼
                                  10.12  DAST (ZAP)
```

---

### 11.2 Prerequisites

The script auto-installs any missing tool using `brew` (macOS) or `apt` (Linux).
No manual setup is required before running it.

| Tool | Auto-installed? | Used for |
|---|---|---|
| `gitleaks` | Yes — GitHub binary release | Step 10.1 |
| `hadolint` | Yes — `brew install hadolint` | Step 10.2 |
| `semgrep` | Yes — `pip3 install semgrep` | Step 10.4 |
| `trivy` | Yes — `brew install trivy` | Step 10.9 |
| `jq` | Yes — `brew install jq` | JSON parsing throughout |
| `node` / `npm` | Yes — `brew install node` | Step 10.7 (ESLint) |
| `podman` | **Must be installed** — not auto-installed | Steps 10.8, 10.9, 10.10, 10.12 |
| `./mvnw` | Already in each service directory | Steps 10.3, 10.5, 10.6, 10.7, 10.10 |

> **NVD API key (optional but strongly recommended)**
> Without one, the first NVD Check download takes 10–30 minutes.
> Get a free key at https://nvd.nist.gov/developers/request-an-api-key

---

### 11.3 Usage

```bash
chmod +x security-pipeline.sh
./security-pipeline.sh [OPTIONS]
```

| Option | Description |
|---|---|
| _(no options)_ | Full 12-step pipeline — installs missing tools, runs everything |
| `--skip-sonar` | Skip SonarQube (10.10) and Quality Gate (10.11) — saves ~5 min + 1.5 GB RAM |
| `--skip-dast` | Skip ZAP scan (10.12) — use when the app is not running |
| `--skip-build` | Skip Maven Build (10.5) and Podman Build (10.8) — use cached JARs/images |
| `--skip-install` | Abort instead of auto-installing a missing tool |
| `--nvd-key KEY` | NVD API key for faster dependency scanning (step 10.6) |
| `--app-url URL` | Base URL for DAST scan (default: `http://localhost`) |
| `--repo DIR` | Repository root directory (default: current working directory) |

Environment variables accepted as alternatives to flags:

| Variable | Equivalent flag |
|---|---|
| `NVD_API_KEY` | `--nvd-key` |
| `APP_URL` | `--app-url` |
| `REPO_DIR` | `--repo` |
| `SONAR_TOKEN` | Pre-existing SonarQube token — skips auto token generation |

---

### 11.4 Common run scenarios

**Before every commit — fast pre-flight check (~2 min):**
```bash
./security-pipeline.sh --skip-sonar --skip-dast --skip-build
```
Runs: Gitleaks → Hadolint → Checkstyle → Semgrep → Trivy config scan

**After a code change — full check without slow steps (~15–20 min):**
```bash
./security-pipeline.sh --skip-sonar --skip-dast --nvd-key $NVD_API_KEY
```
Runs everything except SonarQube and DAST.

**Full pipeline including SonarQube (~25–30 min, needs ~1.5 GB free RAM):**
```bash
./security-pipeline.sh --skip-dast --nvd-key $NVD_API_KEY
```

**Full pipeline with DAST — app must be running via podman-compose:**
```bash
podman-compose up -d                       # ensure stack is running
./security-pipeline.sh --nvd-key $NVD_API_KEY
```

**Re-run only security scans, skip rebuilding (images already built):**
```bash
./security-pipeline.sh --skip-build --skip-sonar --app-url http://localhost
```

**CI non-interactive mode — abort instead of auto-installing tools:**
```bash
./security-pipeline.sh --skip-install --nvd-key $NVD_API_KEY
```

---

### 11.5 Where it fits in the workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Developer Workflow                                                      │
│                                                                         │
│  1. Make code changes                                                   │
│  2. ./security-pipeline.sh --skip-sonar --skip-dast --skip-build        │
│     └─ Gitleaks + Hadolint + Checkstyle + Semgrep + Trivy config        │
│        Quick feedback before building anything                          │
│                                                                         │
│  3. podman-compose up --build -d                                        │
│     └─ Build images + start stack                                       │
│                                                                         │
│  4. ./security-pipeline.sh --skip-sonar --nvd-key $NVD_API_KEY          │
│     └─ Full pipeline including Trivy image scan + DAST against          │
│        the running containers                                           │
│                                                                         │
│  5. Open pull request → GitHub Actions CI runs the same pipeline        │
│     using the GitHub Actions skeleton in §10 Full CI Pipeline           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

### 11.6 Reports

Every run writes a timestamped directory under `/tmp/pipeline-reports/`:

```
/tmp/pipeline-reports/20260801-143022/
├── pipeline.log                  ← combined log of all steps
├── .gitleaks.toml                ← allowlist config used during scan
├── gitleaks.log
├── gitleaks.json                 ← findings (empty array = no secrets)
├── hadolint.log
├── checkstyle.xml                ← embedded ruleset used for the scan
├── checkstyle.log
├── semgrep-java.json             ← Java SAST findings
├── semgrep-js.json               ← React/JS SAST findings
├── semgrep.log
├── build.log
├── nvd.log
│   (HTML + JSON reports also at: */target/dependency-check-report.*)
├── lint.log
├── podman_build.log
├── trivy-config.json             ← Dockerfile + compose misconfiguration findings
├── trivy-image-auth-service.json ← per-image CVE findings
├── trivy-image-issue-service.json
├── trivy-image-api-gateway.json
├── trivy-image-frontend-service.json
├── trivy.log
├── sonar.log
├── sonar-token.txt               ← SonarQube token (used by Quality Gate step)
├── gate.log
├── zap-report.html               ← open in browser for the full ZAP report
└── zap-report.json
```

**SonarQube dashboard** (when step 10.10 runs):

```
URL   : http://localhost:9000
Login : admin
Pass  : PipelineAdmin@1234
```

The SonarQube container is started with `--restart unless-stopped` and persists
between runs. Stop it manually when not needed:

```bash
podman stop sonarqube
podman rm sonarqube
```

---

### 11.7 Terminal output

The script prints colour-coded progress for each step and ends with a summary table:

```
╔════════════════════════════════════════════════════════════╗
║    SECURITY & CODE QUALITY PIPELINE — v2 SUMMARY           ║
╠════════════════════════════════════════════════════════════╣
║  ✔  10.1   Gitleaks          Secret Scanning          1s  ║
║  ✔  10.2   Hadolint          Dockerfile Lint           0s  ║
║  ✔  10.3   Checkstyle        Java Code Style          22s  ║
║  ✔  10.4   Semgrep           SAST                     38s  ║
║  ✔  10.5   Maven Build       Compile & Package       145s  ║
║  ✔  10.6   NVD Check         Dependency CVEs         240s  ║
║  ✔  10.7   Lint              ESLint + SpotBugs        28s  ║
║  ✔  10.8   Podman Build      Container Images        180s  ║
║  ✔  10.9   Trivy             Image + Config Scan      35s  ║
║  ✔  10.10  SonarQube         Quality Analysis         65s  ║
║  ✔  10.11  Quality Gate      Merge/Deploy Gate         8s  ║
║  ✔  10.12  DAST              ZAP Dynamic Scan          95s ║
╠════════════════════════════════════════════════════════════╣
║  ALL CHECKS PASSED — safe to merge/deploy                  ║
║  Pass:12  Fail:0  Skip:0  Total:857s                       ║
║  Reports: /tmp/pipeline-reports/20260801-143022            ║
╚════════════════════════════════════════════════════════════╝
```

When a step fails, it is highlighted in red and the path to its log file is
printed below the table for immediate investigation.

---

## 12. Shutdown & Cleanup

This section covers every level of teardown — from a simple pause that keeps all data,
to a complete wipe of containers, volumes, images, and pipeline artifacts.

---

### 12.1 Stop — keep data (restart later)

Stops all running containers but preserves the MySQL volume and built images.
Use this for a temporary pause — a `podman-compose up -d` will bring everything
back up in seconds.

```bash
podman-compose down
```

Verify everything stopped:

```bash
podman ps                       # should show no issue-app-* containers
podman volume ls                # mysql_data volume still present
```

Restart later:

```bash
podman-compose up -d            # no --build needed — images are cached
```

---

### 12.2 Full reset — wipe database

Stops containers **and deletes the MySQL data volume**. All database tables and rows are
permanently lost. Use this when you want a clean slate (e.g., re-seeding with fresh data,
schema migration testing, or switching between `.env` credentials).

```bash
podman-compose down -v
```

What `-v` removes:
- `mysql_data` named volume → all database contents gone

What it keeps:
- Built container images (fast restart on next `up`)
- Your `.env` file
- Source code and `target/` directories

After the next `podman-compose up -d`, Hibernate re-creates all tables
(`ddl-auto=update` in `docker-compose.yml`) and the `DataSeeder` re-seeds the
admin account.

---

### 12.3 Full clean — remove images too

Removes containers, volumes, **and all locally built images**. The next `up --build`
will re-compile all JARs from scratch and pull base images again (~10–20 min).
Use this to force a completely fresh build or free up significant disk space.

```bash
podman-compose down --rmi all -v
```

What `--rmi all` removes (in addition to `-v`):
- `localhost/sample-spring-bot-application_auth-service:latest`
- `localhost/sample-spring-bot-application_issue-service:latest`
- `localhost/sample-spring-bot-application_api-gateway:latest`
- `localhost/sample-spring-bot-application_frontend-service:latest`

Base images (`mysql:8.0`, `eclipse-temurin:21-jre`, `node:20`, etc.) are **not**
removed — they remain in the local cache so the next build only re-downloads your
application's dependencies, not the base layers.

Check disk space freed:

```bash
podman system df                # shows image/container/volume disk usage
```

---

### 12.4 Nuclear clean — prune entire Podman system

Removes **everything** not currently in use: stopped containers, dangling images,
unused volumes, and the build cache. Run this when you need to reclaim the maximum
amount of disk space.

> **Warning:** This removes volumes from ALL Podman projects, not just this one.
> Only run this if you have no other Podman projects with data you want to keep.

```bash
# Step 1 — stop and remove this project's containers and volumes
podman-compose down -v

# Step 2 — prune all unused Podman resources
podman system prune --all --volumes --force
```

Individual targeted prune commands (safer alternatives):

```bash
# Remove only stopped containers
podman container prune --force

# Remove only dangling (untagged) images
podman image prune --force

# Remove only unused named volumes
podman volume prune --force

# Remove only the build cache
podman system prune --force          # excludes volumes by default
```

After a nuclear clean, verify:

```bash
podman ps -a                         # no containers
podman images                        # only explicitly kept images
podman volume ls                     # no volumes
podman system df                     # all sizes near zero
```

---

### 12.5 Pipeline artifact cleanup

The `security-pipeline.sh` script and SonarQube leave behind reports, containers,
and compiled artifacts. Clean them up as follows.

**Remove pipeline report directories:**

```bash
# Remove all timestamped runs
rm -rf /tmp/pipeline-reports/

# Remove only runs older than 7 days
find /tmp/pipeline-reports -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

**Stop and remove the SonarQube container** (started by `--skip-sonar` off runs):

```bash
podman stop sonarqube
podman rm   sonarqube
podman volume rm sonarqube_data      # removes all SonarQube analysis history
```

**Remove Maven build artifacts** from all three services:

```bash
./auth-service/mvnw  -f auth-service/pom.xml  clean
./issue-service/mvnw -f issue-service/pom.xml clean
./api-gateway/mvnw   -f api-gateway/pom.xml   clean
```

Or in a single pass from the repo root:

```bash
for svc in auth-service issue-service api-gateway; do
  ./${svc}/mvnw -f ${svc}/pom.xml clean -q
done
```

**Remove frontend dependencies and build output:**

```bash
rm -rf frontend-service/node_modules
rm -rf frontend-service/build
```

**Remove OWASP Dependency-Check cached data** (~500 MB on first run):

```bash
rm -rf ~/.owasp/dependency-check-data
```

---

### 12.6 Pod teardown (Section 6 users)

If you deployed using a Podman pod (§6) instead of `podman-compose`:

```bash
# Stop all containers in the pod
podman pod stop issue-tracker

# Remove the pod and all its containers
podman pod rm issue-tracker

# Remove the MySQL data volume
podman volume rm mysql_data

# Remove the built images
podman rmi issue-auth-service issue-issue-service issue-api-gateway issue-frontend

# Disable and remove the systemd units (if §6.7 was followed)
systemctl --user disable --now pod-issue-tracker.service
rm -f ~/.config/systemd/user/pod-issue-tracker.service
rm -f ~/.config/systemd/user/container-issue-app-*.service
systemctl --user daemon-reload
```

---

### 12.7 Podman machine (macOS only)

On macOS, Podman runs inside a lightweight VM managed by `podman machine`.
The commands below control the VM itself — **not the containers inside it**.

**Stop the VM** (frees RAM + CPU — containers are paused, not deleted):

```bash
podman machine stop
```

**Start the VM again** (containers that were running resume automatically):

```bash
podman machine start
```

**Check VM status:**

```bash
podman machine list
```

Expected output when running:

```
NAME                     VM TYPE   CREATED        LAST UP       CPUS   MEMORY    DISK SIZE
podman-machine-default   applehv   14 months ago  2 hours ago   10     14.9GiB   93GiB
```

**Remove the VM entirely** (frees all disk — deletes every container, image, and volume
inside the VM — equivalent to a full system wipe):

```bash
podman machine stop
podman machine rm podman-machine-default
```

Recreate the VM from scratch when needed:

```bash
podman machine init --cpus 4 --memory 8192 --disk-size 60
podman machine start
```

---

### Quick reference — shutdown decision tree

```
Do you want to stop the app?
│
├── YES, temporarily (restart later with data intact)
│       podman-compose down
│
├── YES, and reset the database to a clean state
│       podman-compose down -v
│
├── YES, and force a complete rebuild next time
│       podman-compose down --rmi all -v
│
├── YES, and reclaim all disk space (multi-project safe)
│       podman-compose down -v
│       podman system prune --all --force          # keeps volumes of other projects
│
└── YES, and wipe everything including other projects
        podman-compose down -v
        podman system prune --all --volumes --force
```
