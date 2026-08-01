# Issue Tracker — v1 Deployment Guide

Single-box deployment of the Issue Tracker application: three Spring Boot services behind an
API Gateway, a React frontend served by Nginx, and MySQL as the database — all running on
one Linux host (bare metal, VM, or Multipass instance).

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [MySQL Setup](#3-mysql-setup)
4. [Environment Variables Reference](#4-environment-variables-reference)
5. [Build All Services](#5-build-all-services)
6. [Run as systemd Services](#6-run-as-systemd-services)
7. [Nginx Setup](#7-nginx-setup)
8. [Automated Multipass Deployment](#8-automated-multipass-deployment)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [API Reference](#10-api-reference)
11. [Troubleshooting](#11-troubleshooting)
12. [Security & Code Quality Pipeline](#12-security--code-quality-pipeline)
    - [12.1 Gitleaks](#121-gitleaks--secret-scanning)
    - [12.2 Checkstyle](#122-checkstyle--java-code-style-enforcement)
    - [12.3 Semgrep](#123-semgrep--static-application-security-testing-sast)
    - [12.4 Maven Build](#124-maven-build--mvnw-clean-package--dskiptests--b)
    - [12.5 DAST Audit](#125-dast-audit--dynamic-application-security-testing)
    - [12.6 Lint](#126-lint--frontend--java-code-linting)
    - [12.7 SonarQube](#127-sonarqube--code-quality--security-analysis)
    - [12.8 Quality Gate](#128-quality-gate--mergedeploy-gate)
    - [12.9 NVD Check](#129-nvd-check--dependency-vulnerability-scanning)

---

## 1. Architecture

```
                        ┌─────────────────────────────────┐
  Browser / Client      │          Linux Host              │
        │               │                                  │
        │  HTTP :80      │  ┌──────────────────────────┐   │
        └──────────────►├──┤       Nginx (port 80)     │   │
                        │  │  - serves React static    │   │
                        │  │  - proxies /auth/**       │   │
                        │  │  - proxies /issues/**     │   │
                        │  └────────────┬─────────────┘   │
                        │               │ :8096            │
                        │  ┌────────────▼─────────────┐   │
                        │  │   API Gateway (port 8096) │   │
                        │  │   Spring Cloud Gateway    │   │
                        │  │   JWT validation (HMAC)   │   │
                        │  └──────┬──────────┬─────────┘   │
                        │         │          │              │
                        │      :8097      :8098             │
                        │  ┌────▼────┐  ┌───▼──────┐       │
                        │  │  Auth   │  │  Issue   │       │
                        │  │ Service │  │ Service  │       │
                        │  └────┬────┘  └───┬──────┘       │
                        │       │           │              │
                        │  ┌────▼───────────▼──────┐       │
                        │  │      MySQL 8           │       │
                        │  │  authdb  |  issuedb   │       │
                        │  └───────────────────────┘       │
                        └─────────────────────────────────┘
```

| Service | Port | Framework | Profile (single-box) |
|---|---|---|---|
| api-gateway | 8096 | Spring Boot 3.4.1 + Spring Cloud Gateway | `local` |
| auth-service | 8097 | Spring Boot 4.0.1 + JPA | `prod` |
| issue-service | 8098 | Spring Boot 4.0.1 + JPA | `prod` |
| frontend-service | — | React 19 (CRA) | built as static files |
| Nginx | 80 | — | reverse proxy + static host |
| MySQL | 3306 | MySQL 8 | `authdb` + `issuedb` |

> **Why `local` profile for the gateway?**
> The `prod` profile routes to Docker hostnames (`auth-service`, `issue-service`).
> On a single host without Docker, use `local` so the gateway routes to `localhost:8097/8098`.

---

## 2. Prerequisites

Install the following on the host before proceeding.

| Tool | Version | Install |
|---|---|---|
| Java (JDK) | 17 | `sudo apt install openjdk-17-jdk` |
| Maven | 3.9+ | `sudo apt install maven` |
| Node.js | 18 LTS | see below |
| MySQL | 8.x | `sudo apt install mysql-server` |
| Nginx | latest | `sudo apt install nginx` |
| Git | any | `sudo apt install git` |

**Node.js 18 (via NodeSource):**

```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo bash -
sudo apt install -y nodejs
```

**Verify installs:**

```bash
java -version        # openjdk 17...
mvn -version         # Apache Maven 3.9...
node --version       # v18.x.x
mysql --version      # mysql  Ver 8...
nginx -version       # nginx/1.x.x
```

---

## 3. MySQL Setup

### 3.1 Start MySQL and secure it

```bash
sudo systemctl enable --now mysql
sudo mysql_secure_installation   # follow prompts (optional but recommended)
```

### 3.2 Create databases and application user

```bash
sudo mysql -u root
```

```sql
-- Databases
CREATE DATABASE authdb  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE issuedb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Dedicated application user
CREATE USER 'appuser'@'localhost' IDENTIFIED BY 'StrongPass@2024!';
GRANT ALL PRIVILEGES ON authdb.*  TO 'appuser'@'localhost';
GRANT ALL PRIVILEGES ON issuedb.* TO 'appuser'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> JPA is configured with `ddl-auto=update`, so tables are created automatically on first startup.
> No SQL schema scripts need to be run manually.

---

## 4. Environment Variables Reference

All three Spring Boot services are configured entirely via environment variables.
Set them in the shell, in a `.env` file sourced before startup, or in systemd unit
`EnvironmentFile=` entries.

### 4.1 auth-service

| Variable | Required | Example | Description |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | yes | `prod` | Must be `prod` |
| `SERVER_PORT` | no | `8097` | Defaults to `8097` |
| `SPRING_DATASOURCE_URL` | yes | `jdbc:mysql://localhost:3306/authdb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC` | MySQL JDBC URL |
| `SPRING_DATASOURCE_USERNAME` | yes | `appuser` | DB user |
| `SPRING_DATASOURCE_PASSWORD` | yes | `StrongPass@2024!` | DB password |
| `JWT_SECRET` | yes | `<min 32 chars>` | HMAC-SHA256 signing key — **must match across all three services** |
| `JWT_EXPIRATIONMINUTES` | no | `60` | Token TTL in minutes |
| `APP_ADMIN_EMAIL` | yes | `admin@example.com` | Seeded admin account email |
| `APP_ADMIN_PASSWORD` | yes | `Admin@2024!` | Seeded admin account password |
| `MAIL_ENABLED` | no | `false` | Set `true` only if AWS SES is configured |
| `SES_USERNAME` | if mail | — | AWS SES SMTP username |
| `SES_PASSWORD` | if mail | — | AWS SES SMTP password |

### 4.2 issue-service

| Variable | Required | Example | Description |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | yes | `prod` | Must be `prod` |
| `SERVER_PORT` | no | `8098` | Defaults to `8098` |
| `SPRING_DATASOURCE_URL` | yes | `jdbc:mysql://localhost:3306/issuedb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC` | MySQL JDBC URL |
| `SPRING_DATASOURCE_USERNAME` | yes | `appuser` | DB user |
| `SPRING_DATASOURCE_PASSWORD` | yes | `StrongPass@2024!` | DB password |
| `JWT_SECRET` | yes | `<same as auth-service>` | Must match auth-service and gateway |
| `JWT_EXPIRATIONMINUTES` | no | `60` | Token TTL in minutes |

### 4.3 api-gateway

| Variable | Required | Example | Description |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | yes | `local` | Use `local` on a single box (not `prod`) |
| `SERVER_PORT` | no | `8096` | Defaults to `8096` |
| `JWT_SECRET` | yes | `<same as auth-service>` | Must match auth-service and issue-service |
| `CORS_ALLOWED_ORIGIN` | no | `http://192.168.2.4` | Allowed browser origin; use `*` to allow all |

### 4.4 frontend-service (build-time only)

| Variable | Required | Description |
|---|---|---|
| `REACT_APP_API_BASE_URL` | no | Base URL for API calls. Leave **empty** (`""`) so that axios uses relative paths and Nginx handles routing. Set to `http://<host>` only if the frontend is served from a different host than the API. |

---

## 5. Build All Services

### 5.1 Clone the repository

```bash
git clone -b v1 https://github.com/amitactive2008/sample-spring-boot-application.git
cd sample-spring-boot-application
```

### 5.2 Build auth-service

```bash
cd auth-service
mvn clean package -DskipTests
# output: target/auth-service-0.0.1-SNAPSHOT.jar
cd ..
```

### 5.3 Build issue-service

```bash
cd issue-service
mvn clean package -DskipTests
# output: target/issue-service-0.0.1-SNAPSHOT.jar
cd ..
```

### 5.4 Build api-gateway

```bash
cd api-gateway
mvn clean package -DskipTests
# output: target/api-gateway-0.0.1-SNAPSHOT.jar
cd ..
```

### 5.5 Build React frontend

```bash
cd frontend-service
npm install
REACT_APP_API_BASE_URL="" npm run build
# output: build/  (static files)
cd ..
```

> Set `REACT_APP_API_BASE_URL=""` (empty string) so axios uses relative paths.
> Nginx will proxy `/auth/*` and `/issues/*` to the gateway automatically.

---

## 6. Run as systemd Services

Running each service as a systemd unit ensures they start on boot and restart on failure.

### 6.1 Create a dedicated system user

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin issueapp
sudo chown -R issueapp:issueapp /opt/issue-tracker   # adjust path as needed
```

### 6.2 Create environment files

Create one file per service. Store them in `/etc/issue-tracker/`.

```bash
sudo mkdir -p /etc/issue-tracker
```

**`/etc/issue-tracker/auth-service.env`**

```env
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8097
SPRING_DATASOURCE_URL=jdbc:mysql://localhost:3306/authdb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
SPRING_DATASOURCE_USERNAME=appuser
SPRING_DATASOURCE_PASSWORD=StrongPass@2024!
JWT_SECRET=<your-secret-key-min-32-chars>
JWT_EXPIRATIONMINUTES=60
APP_ADMIN_EMAIL=admin@example.com
APP_ADMIN_PASSWORD=Admin@2024!
MAIL_ENABLED=false
SES_USERNAME=not-configured
SES_PASSWORD=not-configured
```

**`/etc/issue-tracker/issue-service.env`**

```env
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8098
SPRING_DATASOURCE_URL=jdbc:mysql://localhost:3306/issuedb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
SPRING_DATASOURCE_USERNAME=appuser
SPRING_DATASOURCE_PASSWORD=StrongPass@2024!
JWT_SECRET=<same-secret-as-auth-service>
JWT_EXPIRATIONMINUTES=60
```

**`/etc/issue-tracker/api-gateway.env`**

```env
SPRING_PROFILES_ACTIVE=local
SERVER_PORT=8096
JWT_SECRET=<same-secret-as-auth-service>
CORS_ALLOWED_ORIGIN=*
```

Restrict permissions:

```bash
sudo chmod 640 /etc/issue-tracker/*.env
sudo chgrp issueapp /etc/issue-tracker/*.env
```

### 6.3 Create systemd unit files

**`/etc/systemd/system/auth-service.service`**

```ini
[Unit]
Description=Issue Tracker - Auth Service (port 8097)
After=network.target mysql.service
Requires=mysql.service

[Service]
Type=simple
User=issueapp
Group=issueapp
EnvironmentFile=/etc/issue-tracker/auth-service.env
ExecStart=/usr/bin/java -jar /opt/issue-tracker/auth-service/target/auth-service-0.0.1-SNAPSHOT.jar
Restart=on-failure
RestartSec=15
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal
SyslogIdentifier=auth-service

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/issue-service.service`**

```ini
[Unit]
Description=Issue Tracker - Issue Service (port 8098)
After=network.target mysql.service
Requires=mysql.service

[Service]
Type=simple
User=issueapp
Group=issueapp
EnvironmentFile=/etc/issue-tracker/issue-service.env
ExecStart=/usr/bin/java -jar /opt/issue-tracker/issue-service/target/issue-service-0.0.1-SNAPSHOT.jar
Restart=on-failure
RestartSec=15
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal
SyslogIdentifier=issue-service

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/api-gateway.service`**

```ini
[Unit]
Description=Issue Tracker - API Gateway (port 8096)
After=network.target auth-service.service issue-service.service

[Service]
Type=simple
User=issueapp
Group=issueapp
EnvironmentFile=/etc/issue-tracker/api-gateway.env
ExecStart=/usr/bin/java -jar /opt/issue-tracker/api-gateway/target/api-gateway-0.0.1-SNAPSHOT.jar
Restart=on-failure
RestartSec=15
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal
SyslogIdentifier=api-gateway

[Install]
WantedBy=multi-user.target
```

### 6.4 Enable and start services

```bash
sudo systemctl daemon-reload

# Enable on boot
sudo systemctl enable auth-service issue-service api-gateway

# Start (in order — auth first so the admin seed runs before gateway starts)
sudo systemctl start auth-service
sleep 20   # allow Spring context + DB migration to complete

sudo systemctl start issue-service
sleep 10

sudo systemctl start api-gateway
```

**Check status:**

```bash
sudo systemctl status auth-service issue-service api-gateway
```

**Follow live logs:**

```bash
sudo journalctl -u auth-service  -f
sudo journalctl -u issue-service -f
sudo journalctl -u api-gateway   -f
```

---

## 7. Nginx Setup

Nginx serves two roles:
- **Static file server** — React build artifacts (`/opt/issue-tracker/frontend-service/build`)
- **Reverse proxy** — forwards `/auth/*` and `/issues/*` to the API Gateway on port 8096

### 7.1 Create the virtual-host config

**`/etc/nginx/sites-available/issue-tracker`**

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # React frontend (built static assets)
    root /opt/issue-tracker/frontend-service/build;
    index index.html;

    # ── Auth routes → API Gateway ─────────────────────────────────────────
    location /auth/ {
        proxy_pass         http://127.0.0.1:8096;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_connect_timeout 30s;
        proxy_read_timeout    60s;
    }

    # ── Issues routes → API Gateway ──────────────────────────────────────
    location /issues {
        proxy_pass         http://127.0.0.1:8096;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_connect_timeout 30s;
        proxy_read_timeout    60s;
    }

    # ── React SPA fallback (client-side routing) ─────────────────────────
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

### 7.2 Enable the site and reload

```bash
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/issue-tracker /etc/nginx/sites-enabled/issue-tracker

sudo nginx -t          # test config
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

---

## 8. Automated Multipass Deployment

If you want a clean, isolated VM with everything provisioned automatically, use
[Multipass](https://multipass.run) with the provided `cloud-init` file.

### 8.1 Install Multipass (macOS)

```bash
brew install --cask multipass
```

### 8.2 Create `cloud-init.yaml`

Save the following as `cloud-init.yaml`. Edit the credentials under
`write_files` before running.

```yaml
#cloud-config
package_update: true
package_upgrade: false

packages:
  - openjdk-17-jdk
  - maven
  - mysql-server
  - nginx
  - git
  - curl

write_files:

  - path: /etc/issue-tracker/auth-service.env
    owner: root:root
    permissions: '0640'
    content: |
      SPRING_PROFILES_ACTIVE=prod
      SERVER_PORT=8097
      SPRING_DATASOURCE_URL=jdbc:mysql://localhost:3306/authdb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
      SPRING_DATASOURCE_USERNAME=appuser
      SPRING_DATASOURCE_PASSWORD=StrongPass@2024!
      JWT_SECRET=ReplaceThisWithASecureSecretKeyOfAtLeast32Chars
      JWT_EXPIRATIONMINUTES=60
      APP_ADMIN_EMAIL=admin@example.com
      APP_ADMIN_PASSWORD=Admin@2024!
      MAIL_ENABLED=false
      SES_USERNAME=not-configured
      SES_PASSWORD=not-configured

  - path: /etc/issue-tracker/issue-service.env
    owner: root:root
    permissions: '0640'
    content: |
      SPRING_PROFILES_ACTIVE=prod
      SERVER_PORT=8098
      SPRING_DATASOURCE_URL=jdbc:mysql://localhost:3306/issuedb?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
      SPRING_DATASOURCE_USERNAME=appuser
      SPRING_DATASOURCE_PASSWORD=StrongPass@2024!
      JWT_SECRET=ReplaceThisWithASecureSecretKeyOfAtLeast32Chars
      JWT_EXPIRATIONMINUTES=60

  - path: /etc/issue-tracker/api-gateway.env
    owner: root:root
    permissions: '0640'
    content: |
      SPRING_PROFILES_ACTIVE=local
      SERVER_PORT=8096
      JWT_SECRET=ReplaceThisWithASecureSecretKeyOfAtLeast32Chars
      CORS_ALLOWED_ORIGIN=*

  - path: /etc/systemd/system/auth-service.service
    content: |
      [Unit]
      Description=Issue Tracker - Auth Service (port 8097)
      After=network.target mysql.service
      Requires=mysql.service
      [Service]
      Type=simple
      User=issueapp
      Group=issueapp
      EnvironmentFile=/etc/issue-tracker/auth-service.env
      ExecStart=/usr/bin/java -jar /opt/issue-tracker/auth-service/target/auth-service-0.0.1-SNAPSHOT.jar
      Restart=on-failure
      RestartSec=15
      SuccessExitStatus=143
      StandardOutput=journal
      StandardError=journal
      SyslogIdentifier=auth-service
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/issue-service.service
    content: |
      [Unit]
      Description=Issue Tracker - Issue Service (port 8098)
      After=network.target mysql.service
      Requires=mysql.service
      [Service]
      Type=simple
      User=issueapp
      Group=issueapp
      EnvironmentFile=/etc/issue-tracker/issue-service.env
      ExecStart=/usr/bin/java -jar /opt/issue-tracker/issue-service/target/issue-service-0.0.1-SNAPSHOT.jar
      Restart=on-failure
      RestartSec=15
      SuccessExitStatus=143
      StandardOutput=journal
      StandardError=journal
      SyslogIdentifier=issue-service
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/api-gateway.service
    content: |
      [Unit]
      Description=Issue Tracker - API Gateway (port 8096)
      After=network.target auth-service.service issue-service.service
      [Service]
      Type=simple
      User=issueapp
      Group=issueapp
      EnvironmentFile=/etc/issue-tracker/api-gateway.env
      ExecStart=/usr/bin/java -jar /opt/issue-tracker/api-gateway/target/api-gateway-0.0.1-SNAPSHOT.jar
      Restart=on-failure
      RestartSec=15
      SuccessExitStatus=143
      StandardOutput=journal
      StandardError=journal
      SyslogIdentifier=api-gateway
      [Install]
      WantedBy=multi-user.target

  - path: /etc/nginx/sites-available/issue-tracker
    content: |
      server {
          listen 80 default_server;
          listen [::]:80 default_server;
          server_name _;
          root /opt/issue-tracker/frontend-service/build;
          index index.html;
          location /auth/ {
              proxy_pass http://127.0.0.1:8096;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_read_timeout 60s;
          }
          location /issues {
              proxy_pass http://127.0.0.1:8096;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_read_timeout 60s;
          }
          location / {
              try_files $uri $uri/ /index.html;
          }
      }

  - path: /opt/provision.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > >(tee -a /var/log/issue-tracker-setup.log) 2>&1
      echo "=== Provisioning started: $(date) ==="

      # Wait for MySQL
      for i in $(seq 1 30); do
        mysql -u root -e "SELECT 1;" &>/dev/null && break || sleep 3
      done

      # Create databases + user
      mysql -u root <<'SQL'
      CREATE DATABASE IF NOT EXISTS authdb  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE DATABASE IF NOT EXISTS issuedb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS 'appuser'@'localhost' IDENTIFIED BY 'StrongPass@2024!';
      GRANT ALL PRIVILEGES ON authdb.*  TO 'appuser'@'localhost';
      GRANT ALL PRIVILEGES ON issuedb.* TO 'appuser'@'localhost';
      FLUSH PRIVILEGES;
      SQL

      # Node.js 18
      curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
      apt-get install -y nodejs >/dev/null 2>&1

      # Clone
      git clone --branch v1 --depth 1 \
        https://github.com/amitactive2008/sample-spring-boot-application.git \
        /opt/issue-tracker

      # Maven builds
      mvn -f /opt/issue-tracker/auth-service/pom.xml  clean package -DskipTests -q
      mvn -f /opt/issue-tracker/issue-service/pom.xml clean package -DskipTests -q
      mvn -f /opt/issue-tracker/api-gateway/pom.xml   clean package -DskipTests -q

      # React build
      cd /opt/issue-tracker/frontend-service
      REACT_APP_API_BASE_URL="" npm install --silent
      REACT_APP_API_BASE_URL="" npm run build

      # System user + permissions
      useradd --system --no-create-home --shell /usr/sbin/nologin issueapp 2>/dev/null || true
      chown -R issueapp:issueapp /opt/issue-tracker
      chgrp issueapp /etc/issue-tracker/*.env

      # Nginx
      rm -f /etc/nginx/sites-enabled/default
      ln -sf /etc/nginx/sites-available/issue-tracker /etc/nginx/sites-enabled/issue-tracker
      nginx -t && systemctl enable --now nginx && systemctl reload nginx

      # Spring Boot services
      systemctl daemon-reload
      systemctl enable auth-service issue-service api-gateway
      systemctl start auth-service && sleep 20
      systemctl start issue-service && sleep 10
      systemctl start api-gateway

      echo "=== Provisioning complete: $(date) ==="
      echo "Frontend: http://$(hostname -I | awk '{print $1}')/"

runcmd:
  - /opt/provision.sh
```

### 8.3 Launch the VM

```bash
multipass launch \
  --name issue-tracker-v1 \
  --cpus 2 \
  --memory 4G \
  --disk 20G \
  --cloud-init cloud-init.yaml \
  22.04
```

> The `multipass launch` command waits for cloud-init to finish.
> Total time is approximately **20–30 minutes** (Maven and npm dependency downloads).

### 8.4 Get the VM IP

```bash
multipass info issue-tracker-v1
# look for IPv4: 192.168.x.x
```

### 8.5 Useful Multipass commands

```bash
# Open a shell in the VM
multipass shell issue-tracker-v1

# Follow the provisioning log
multipass exec issue-tracker-v1 -- tail -f /var/log/issue-tracker-setup.log

# Stop / Start / Delete
multipass stop   issue-tracker-v1
multipass start  issue-tracker-v1
multipass delete issue-tracker-v1 && multipass purge
```

---

## 9. Verify the Deployment

Replace `<HOST>` with the server IP or `localhost`.

### 9.1 Service health

```bash
# All four services should show "active (running)"
systemctl is-active auth-service issue-service api-gateway nginx

# Or on the Multipass VM:
multipass exec issue-tracker-v1 -- \
  systemctl is-active auth-service issue-service api-gateway nginx
```

### 9.2 Port checks

```bash
ss -tlnp | grep -E '8096|8097|8098|:80'
```

Expected output:

```
LISTEN  0  128  0.0.0.0:80    ...  nginx
LISTEN  0  128  0.0.0.0:8096  ...  java (api-gateway)
LISTEN  0  128  0.0.0.0:8097  ...  java (auth-service)
LISTEN  0  128  0.0.0.0:8098  ...  java (issue-service)
```

### 9.3 Smoke tests

```bash
# Public auth endpoints (through Nginx → Gateway)
curl -s -o /dev/null -w "%{http_code}" http://<HOST>/auth/login \
  -X POST -H "Content-Type: application/json" \
  -d '{"email":"wrong@x.com","password":"bad"}'
# expected: 401 or 400

# Login with seeded admin
curl -s http://<HOST>/auth/login \
  -X POST -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin@2024!"}'
# expected: {"accessToken":"eyJ...","role":"ADMIN","email":"admin@example.com"}

# Frontend
curl -s -o /dev/null -w "%{http_code}" http://<HOST>/
# expected: 200
```

### 9.4 Open the UI

Navigate to `http://<HOST>/` in a browser.

Login with the seeded admin credentials (`APP_ADMIN_EMAIL` / `APP_ADMIN_PASSWORD`)
set in the environment file.

---

## 10. API Reference

All requests go through **Nginx → API Gateway** on port 80 in production.
For direct service testing, use ports 8097 / 8098.

### 10.1 Auth Service (`/auth`)

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/auth/register` | Public | Register a new user |
| `POST` | `/auth/login` | Public | Login and receive JWT |
| `GET` | `/auth/users` | ADMIN | List all users |
| `GET` | `/auth/users/{id}` | ADMIN | Get user by ID |
| `DELETE` | `/auth/users/{id}` | ADMIN | Delete a user |

**Register:**

```bash
curl -X POST http://<HOST>/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"MyPass@123"}'
```

**Login (returns JWT):**

```bash
TOKEN=$(curl -s -X POST http://<HOST>/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"MyPass@123"}' \
  | jq -r '.accessToken')
```

### 10.2 Issue Service (`/issues`)

All endpoints require a valid JWT (`Authorization: Bearer <token>`).

| Method | Path | Role | Description |
|---|---|---|---|
| `POST` | `/issues` | USER, ADMIN | Create an issue |
| `GET` | `/issues` | USER, ADMIN | List issues (paginated, filterable) |
| `GET` | `/issues/{id}` | USER, ADMIN | Get issue by ID |
| `PUT` | `/issues/{id}` | USER, ADMIN | Update an issue |
| `PATCH` | `/issues/{id}/status` | USER, ADMIN | Update issue status |
| `GET` | `/issues/{id}/history` | USER, ADMIN | Get status change history |
| `GET` | `/issues/count-by-status` | USER, ADMIN | Counts grouped by status |
| `DELETE` | `/issues/{id}` | USER, ADMIN | Delete an issue |

**Create an issue:**

```bash
curl -X POST http://<HOST>/issues \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Login page crash on Safari",
    "description": "Reproducible on Safari 17",
    "priority": "HIGH",
    "severity": "CRITICAL"
  }'
```

**List issues with filters:**

```bash
curl "http://<HOST>/issues?status=OPEN&priority=HIGH&page=0&size=10&sort=createdAt,desc" \
  -H "Authorization: Bearer $TOKEN"
```

**Update status:**

```bash
curl -X PATCH http://<HOST>/issues/1/status \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"IN_PROGRESS"}'
```

**Valid enum values:**

| Field | Values |
|---|---|
| `status` | `OPEN`, `IN_PROGRESS`, `RESOLVED`, `CLOSED` |
| `priority` | `LOW`, `MEDIUM`, `HIGH`, `URGENT` |
| `severity` | `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` |

---

## 11. Troubleshooting

### Service fails to start

```bash
sudo journalctl -u auth-service --since "5 min ago" --no-pager
```

Common causes:

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Access denied for user 'appuser'` | Wrong DB credentials in env file | Verify `SPRING_DATASOURCE_PASSWORD` matches MySQL |
| `Communications link failure` | MySQL not running | `sudo systemctl start mysql` |
| `JWT secret too short` | `JWT_SECRET` under 32 chars | Use a longer key |
| `Port 8097 already in use` | Another process on the port | `sudo fuser -k 8097/tcp` |
| `Address already in use :80` | Another web server on port 80 | `sudo systemctl stop apache2` |

### Nginx returns 502 Bad Gateway

The API Gateway is not reachable. Check:

```bash
sudo systemctl status api-gateway
curl -s http://localhost:8096/actuator/health   # should return {"status":"UP"}
```

### Frontend loads but API calls fail (CORS / 404)

- Confirm `REACT_APP_API_BASE_URL` was set to `""` at build time.
- Check Nginx config has the `/auth/` and `/issues` location blocks.
- Verify `CORS_ALLOWED_ORIGIN` in `api-gateway.env` includes the browser origin.

### Reset the database

```bash
sudo mysql -u root -e "DROP DATABASE authdb; DROP DATABASE issuedb;"
# Then re-create (see Section 3.2)
# Restart auth-service to re-seed the admin user
sudo systemctl restart auth-service
```

### Provisioning log (Multipass)

```bash
multipass exec issue-tracker-v1 -- sudo cat /var/log/issue-tracker-setup.log
```

---

## 12. Security & Code Quality Pipeline

In a production-grade SDLC, code must pass a sequence of automated checks before it is
allowed to merge and deploy. The eight tools below form a defense-in-depth pipeline that
covers everything from secret leakage in git history all the way to runtime vulnerability
scanning of the deployed application.

```
Developer push / Pull Request
          │
          ▼
  ┌───────────────┐
  │  1. Gitleaks  │  ← Did you accidentally commit a password or JWT secret?
  └───────┬───────┘
          │
          ▼
  ┌────────────────┐
  │ 2. Checkstyle  │  ← Does your Java code follow the agreed style rules?
  └───────┬────────┘
          │
          ▼
  ┌──────────────┐
  │   3. Semgrep │  ← Are there security anti-patterns in source code? (SAST)
  └──────┬───────┘
          │
          ▼
  ┌──────────────────────────────────────┐
  │  4. ./mvnw clean package -DskipTests │  ← Does the code actually compile and package?
  └──────────────────┬───────────────────┘
          │
          ▼
  ┌────────────────────┐
  │  9. NVD Check      │  ← Do any dependencies have known CVEs? (SCA)
  └────────┬───────────┘
          │
          ▼
  ┌──────────────┐
  │   6. Lint    │  ← Does the React frontend follow ESLint rules?
  └──────┬───────┘
          │
          ▼
  ┌─────────────┐
  │ 7. SonarQube│  ← Deeper quality scan: bugs, smells, coverage, vulnerabilities
  └──────┬──────┘
          │
          ▼
  ┌────────────────┐
  │ 8. Quality Gate│  ← Hard pass/fail threshold — blocks merge if not met
  └──────┬─────────┘
          │
       MERGE
          │
     Deploy to staging
          │
          ▼
  ┌──────────────────┐
  │  5. DAST Audit   │  ← Probe the running application for runtime vulnerabilities
  └──────────────────┘
          │
     Deploy to production
```

Each tool is described below: what it does, where it provides value in the SDLC, and
exactly how to apply it to this project.

---

### 12.1 Gitleaks — Secret Scanning

**What it is:**
Gitleaks scans git commits and history for accidentally committed secrets — passwords,
API keys, JWT secrets, private keys, connection strings — using a library of regular
expression rules. It can also be installed as a pre-commit hook so secrets are blocked
before they ever reach the remote repository.

**SDLC value:**
Secrets in version control are one of the most common and damaging security incidents.
A developer who accidentally commits a `.env` file or hardcodes `JWT_SECRET` in source
code creates a permanent credential leak in git history that survives even after the file
is deleted. Gitleaks catches this at the earliest possible moment — before the commit
lands.

This project is specifically at risk because:
- `JWT_SECRET` is shared across all three services and is the master key for all tokens.
- `SPRING_DATASOURCE_PASSWORD`, `APP_ADMIN_PASSWORD`, and AWS SES credentials are
  referenced via environment variables — but a developer under pressure might hardcode
  them.

**How to apply:**

Install:
```bash
# macOS
brew install gitleaks

# Linux (download binary)
curl -sSL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_linux_x64.tar.gz \
  | tar -xz && sudo mv gitleaks /usr/local/bin/
```

Scan the full repository history:
```bash
gitleaks detect --source . --verbose
```

Scan only changes in a pull request (CI usage):
```bash
gitleaks detect --source . --log-opts="origin/main..HEAD" --verbose
```

Install as a pre-commit hook so it runs automatically on every `git commit`:
```bash
# Install pre-commit framework
pip install pre-commit

# Create .pre-commit-config.yaml at repo root
cat > .pre-commit-config.yaml <<'EOF'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
EOF

pre-commit install
```

Create `.gitleaks.toml` at the repo root to suppress false positives
(e.g., test fixtures with dummy tokens):

```toml
# .gitleaks.toml
title = "Issue Tracker Gitleaks Config"

[allowlist]
description = "Ignore test fixtures and documentation examples"
regexes = [
  "ReplaceThisWithASecureSecretKeyOfAtLeast32Chars",
  "not-configured",
  "dummy"
]
```

> **Critical rule for this project:** Never commit a real value for `JWT_SECRET`,
> `SPRING_DATASOURCE_PASSWORD`, `APP_ADMIN_PASSWORD`, `SES_USERNAME`, or `SES_PASSWORD`.
> All must stay as environment variables. Add all `*.env` files to `.gitignore`.

---

### 12.2 Checkstyle — Java Code Style Enforcement

**What it is:**
Checkstyle is a Maven plugin that statically analyses Java source code against a
configurable ruleset (e.g., Google Java Style or a custom company standard). It checks
naming conventions, import ordering, Javadoc presence, line length, whitespace, and
hundreds of other style rules. Violations fail the build.

**SDLC value:**
Inconsistent code style makes code reviews slower and diffs noisier. Enforcing style
automatically means reviewers can focus on logic, not formatting. It also prevents
common pitfalls like missing braces around `if` blocks (which historically caused
serious security bugs). Running it in CI means no style-violating code ever merges.

**How to apply:**

Add the plugin to the `<build><plugins>` section of **each** Java service's `pom.xml`
(`auth-service/pom.xml`, `issue-service/pom.xml`, `api-gateway/pom.xml`):

```xml
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-checkstyle-plugin</artifactId>
    <version>3.3.1</version>
    <configuration>
        <configLocation>checkstyle.xml</configLocation>
        <consoleOutput>true</consoleOutput>
        <failsOnError>true</failsOnError>
        <includeTestSourceDirectory>true</includeTestSourceDirectory>
    </configuration>
    <executions>
        <execution>
            <id>checkstyle-validate</id>
            <phase>validate</phase>
            <goals>
                <goal>check</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

Create `checkstyle.xml` at the root of each service (or in a shared parent directory).
A minimal ruleset appropriate for this project:

```xml
<?xml version="1.0"?>
<!DOCTYPE module PUBLIC
    "-//Checkstyle//DTD Checkstyle Configuration 1.3//EN"
    "https://checkstyle.org/dtds/configuration_1_3.dtd">

<module name="Checker">
    <property name="charset" value="UTF-8"/>
    <property name="severity" value="error"/>

    <!-- File-level checks -->
    <module name="FileTabCharacter"/>
    <module name="NewlineAtEndOfFile"/>

    <module name="TreeWalker">
        <!-- Naming -->
        <module name="TypeName"/>
        <module name="ConstantName"/>
        <module name="LocalVariableName"/>
        <module name="MethodName"/>
        <module name="PackageName"/>

        <!-- Imports -->
        <module name="AvoidStarImport"/>
        <module name="UnusedImports"/>

        <!-- Code quality -->
        <module name="SimplifyBooleanExpression"/>
        <module name="SimplifyBooleanReturn"/>
        <module name="EmptyBlock"/>
        <module name="NeedBraces"/>       <!-- prevents single-line if without braces -->
        <module name="EqualsHashCode"/>   <!-- if you override equals(), override hashCode() -->

        <!-- Whitespace -->
        <module name="WhitespaceAround"/>
        <module name="NoWhitespaceAfter"/>

        <!-- Misc -->
        <module name="UpperEll"/>         <!-- use L not l for long literals -->
    </module>
</module>
```

Run manually:
```bash
cd auth-service && mvn checkstyle:check
cd issue-service && mvn checkstyle:check
cd api-gateway  && mvn checkstyle:check
```

Because the plugin is bound to the `validate` phase, it also runs automatically as part
of the normal build:
```bash
mvn clean package   # checkstyle runs before compile
```

---

### 12.3 Semgrep — Static Application Security Testing (SAST)

**What it is:**
Semgrep is an open-source SAST tool that finds security vulnerabilities and code bugs by
pattern-matching against a large community ruleset. Unlike Checkstyle (style) or
SonarQube (quality), Semgrep focuses specifically on security anti-patterns: insecure
cryptography, SQL injection, hardcoded credentials, path traversal, SSRF, JWT misuse,
XSS, and more. It supports Java, JavaScript/TypeScript, and dozens of other languages in
one pass.

**SDLC value:**
SAST runs on source code without executing the application, so it catches vulnerabilities
at the pull-request stage — before code is merged, built, or deployed. Fixing a security
flaw pre-merge costs a fraction of fixing it post-production. Semgrep's Spring and OWASP
rulesets are directly applicable to this project's tech stack.

Relevant risks in this project that Semgrep detects:
- Weak JWT secret (secret derived from a short string)
- `ddl-auto=update` / `ddl-auto=create` in prod (schema changes without migration control)
- `@CrossOrigin` without explicit origin restriction
- Unvalidated redirect in Spring controllers
- React XSS via `dangerouslySetInnerHTML`

**How to apply:**

Install:
```bash
# macOS / Linux
pip install semgrep
# or
brew install semgrep
```

Run against all Java services:
```bash
# Spring Security rules (JWT, auth, CSRF, injection)
semgrep --config p/spring-security   auth-service/src issue-service/src api-gateway/src

# General Java quality + security
semgrep --config p/java              auth-service/src issue-service/src api-gateway/src

# OWASP Top 10 mappings
semgrep --config p/owasp-top-ten     auth-service/src issue-service/src api-gateway/src
```

Run against the React frontend:
```bash
semgrep --config p/javascript        frontend-service/src
semgrep --config p/react             frontend-service/src
```

Run everything in one CI command from the repo root:
```bash
semgrep \
  --config p/spring-security \
  --config p/java \
  --config p/owasp-top-ten \
  --config p/javascript \
  --config p/react \
  --error \       # exit non-zero on findings (blocks CI)
  .
```

Generate a SARIF report for upload to GitHub Advanced Security:
```bash
semgrep --config p/spring-security . --sarif --output semgrep.sarif
```

Add a `.semgrepignore` to exclude generated and test code:
```
# .semgrepignore
**/target/
**/node_modules/
**/build/
**/*.min.js
```

---

### 12.4 Maven Build — `./mvnw clean package -DskipTests -B`

**What it is:**
This is the standard Maven lifecycle command that compiles all sources, runs annotation
processors (Lombok, Spring Boot), and packages the application into a fat JAR. The flags
mean:
- `clean` — delete previous `target/` output (ensures a fresh, reproducible build)
- `package` — compile, process resources, run unit tests (if not skipped), and jar
- `-DskipTests` — skip test execution during this step (tests run in a dedicated stage)
- `-B` — batch mode: suppresses interactive prompts and download progress bars, which
  keeps CI logs readable

**SDLC value:**
The build step is the gateway that proves the code compiles correctly and all Maven
dependencies resolve. A broken build fails fast and blocks the pipeline immediately — no
point running security or quality scans on code that doesn't compile. In CI, `-B` ensures
the build never hangs waiting for input, and `clean` prevents stale artifact contamination
between runs.

**How to apply to each service:**

```bash
# From repo root — build all three services
cd auth-service  && ./mvnw clean package -DskipTests -B && cd ..
cd issue-service && ./mvnw clean package -DskipTests -B && cd ..
cd api-gateway   && ./mvnw clean package -DskipTests -B && cd ..
```

Or using the Maven wrapper's `-f` flag (no need to `cd`):
```bash
./auth-service/mvnw  -f auth-service/pom.xml  clean package -DskipTests -B
./issue-service/mvnw -f issue-service/pom.xml clean package -DskipTests -B
./api-gateway/mvnw   -f api-gateway/pom.xml   clean package -DskipTests -B
```

In CI (GitHub Actions example):
```yaml
- name: Build auth-service
  run: ./mvnw clean package -DskipTests -B
  working-directory: auth-service

- name: Build issue-service
  run: ./mvnw clean package -DskipTests -B
  working-directory: issue-service

- name: Build api-gateway
  run: ./mvnw clean package -DskipTests -B
  working-directory: api-gateway
```

Produced artifacts:
```
auth-service/target/auth-service-0.0.1-SNAPSHOT.jar
issue-service/target/issue-service-0.0.1-SNAPSHOT.jar
api-gateway/target/api-gateway-0.0.1-SNAPSHOT.jar
```

> These JARs are what the systemd units in Section 6 execute.

---

### 12.5 DAST Audit — Dynamic Application Security Testing

**What it is:**
DAST (Dynamic Application Security Testing) probes a **running** application from the
outside — exactly as an attacker would. A DAST scanner sends crafted HTTP requests to
discover vulnerabilities like SQL injection, XSS, broken authentication, insecure HTTP
headers, open redirects, and CSRF. Unlike SAST (which reads source code), DAST can find
runtime issues that only appear when the application is actually executing with a real
database and real network stack.

**SDLC value:**
DAST is the closest thing to a real attack. It validates that the security controls in
the code (JWT validation in the gateway, input validation in Spring, Nginx headers)
actually work end-to-end in the deployed environment. It runs against the staging
deployment after code merges and before production promotion. Issues found here reflect
what a real attacker would find and exploit.

Specific risks DAST targets in this project:
- Missing HTTP security headers (no `X-Content-Type-Options`, `X-Frame-Options`, `CSP`)
- JWT endpoint brute-force (`/auth/login` with no rate limiting)
- SQL injection through issue query parameters (`?title=`, `?status=`)
- Insecure CORS configuration (`CORS_ALLOWED_ORIGIN=*` in the gateway)
- Unauthenticated access to protected endpoints

**How to apply using OWASP ZAP:**

Install OWASP ZAP (the industry-standard DAST tool):
```bash
# Docker (recommended for CI)
docker pull ghcr.io/zaproxy/zaproxy:stable
```

Run a baseline passive scan against the Nginx endpoint (safe — no active attacks):
```bash
docker run --rm ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
  -t http://<VM_IP>/ \
  -r zap-baseline-report.html \
  -I   # do not fail on warnings, only on errors
```

Run a full active scan (tests SQL injection, XSS, path traversal, etc.):
```bash
docker run --rm ghcr.io/zaproxy/zaproxy:stable zap-full-scan.py \
  -t http://<VM_IP>/ \
  -r zap-full-report.html
```

Scan only the authenticated API endpoints (pass a JWT token):
```bash
# 1. Get a token first
TOKEN=$(curl -s -X POST http://<VM_IP>/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin@2024!"}' \
  | jq -r '.accessToken')

# 2. Run ZAP API scan with the token in the Authorization header
docker run --rm ghcr.io/zaproxy/zaproxy:stable zap-api-scan.py \
  -t http://<VM_IP>/issues \
  -f openapi \
  -z "-config replacer.full_list(0).description=auth-header \
      -config replacer.full_list(0).enabled=true \
      -config replacer.full_list(0).matchtype=REQ_HEADER \
      -config replacer.full_list(0).matchstr=Authorization \
      -config replacer.full_list(0).replacement=Bearer\ ${TOKEN}"
```

**Hardening Nginx to address common DAST findings** —
add these headers to the `server {}` block in `/etc/nginx/sites-available/issue-tracker`:

```nginx
# Security headers
add_header X-Content-Type-Options  "nosniff"           always;
add_header X-Frame-Options         "DENY"              always;
add_header X-XSS-Protection        "1; mode=block"     always;
add_header Referrer-Policy         "strict-origin"     always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';" always;
add_header Permissions-Policy      "geolocation=(), microphone=()" always;

# Hide server version
server_tokens off;
```

---

### 12.6 Lint — Frontend & Java Code Linting

**What it is:**
Linting is automated static analysis that enforces coding rules beyond raw style — it
catches logical bugs, deprecated API usage, accessibility violations, unused variables,
and potential runtime errors before the code runs. For Java services, this overlaps with
Checkstyle but goes deeper (SpotBugs detects null pointer risks, resource leaks). For
React/JavaScript, ESLint is the standard linter and is already partially configured in
this project via `react-scripts`.

**SDLC value:**
Linting is the fastest feedback loop in the pipeline — it runs in milliseconds directly in
the developer's editor and again in CI. It prevents entire categories of bugs (null
dereferences, missing `key` props in React lists, unreachable code) from ever being
reviewed. For security-sensitive code like JWT handling and authentication flows, lint
rules can enforce patterns like always using `===` over `==` in JavaScript.

**How to apply to the React frontend:**

The project already has ESLint configured via the `eslintConfig` key in
`frontend-service/package.json`. Add a dedicated `lint` script so it can be run
explicitly in CI:

```json
"scripts": {
  "start":  "react-scripts start",
  "build":  "react-scripts build",
  "test":   "react-scripts test",
  "eject":  "react-scripts eject",
  "lint":   "eslint src --ext .js,.jsx --max-warnings 0"
}
```

Run the linter:
```bash
cd frontend-service
npm run lint
```

`--max-warnings 0` means any ESLint warning fails the CI step — warnings are treated as
errors. This prevents gradual accumulation of ignored issues.

Extend the ESLint config for stricter security rules:

```json
"eslintConfig": {
  "extends": [
    "react-app",
    "react-app/jest"
  ],
  "rules": {
    "no-eval": "error",
    "no-implied-eval": "error",
    "no-new-func": "error",
    "no-script-url": "error",
    "no-unused-vars": "warn",
    "react/no-danger": "error"
  }
}
```

> `react/no-danger` blocks `dangerouslySetInnerHTML`, which is the React vector for XSS.

**How to apply to Java services (SpotBugs):**

SpotBugs finds real bugs (not just style issues): null pointer dereferences, resource
leaks, insecure random number usage, and security vulnerabilities via the FindSecBugs
plugin. Add to each service's `pom.xml`:

```xml
<plugin>
    <groupId>com.github.spotbugs</groupId>
    <artifactId>spotbugs-maven-plugin</artifactId>
    <version>4.8.3.1</version>
    <dependencies>
        <!-- FindSecBugs: security-specific bug patterns -->
        <dependency>
            <groupId>com.h3xstream.findsecbugs</groupId>
            <artifactId>findsecbugs-plugin</artifactId>
            <version>1.13.0</version>
        </dependency>
    </dependencies>
    <configuration>
        <effort>Max</effort>
        <threshold>Low</threshold>
        <failOnError>true</failOnError>
        <plugins>
            <plugin>
                <groupId>com.h3xstream.findsecbugs</groupId>
                <artifactId>findsecbugs-plugin</artifactId>
                <version>1.13.0</version>
            </plugin>
        </plugins>
    </configuration>
    <executions>
        <execution>
            <goals><goal>check</goal></goals>
        </execution>
    </executions>
</plugin>
```

Run:
```bash
cd auth-service  && mvn spotbugs:check
cd issue-service && mvn spotbugs:check
cd api-gateway   && mvn spotbugs:check
```

---

### 12.7 SonarQube — Code Quality & Security Analysis

**What it is:**
SonarQube is a continuous inspection platform that performs deep static analysis of source
code, tracking bugs, vulnerabilities, code smells, code duplication, and test coverage
across the entire codebase over time. It understands Java, JavaScript, and TypeScript
natively and has dedicated security rulesets for OWASP Top 10, CWE, and SANS Top 25.
Unlike Semgrep (which scans a single commit), SonarQube builds a persistent view of
quality trends across every build.

**SDLC value:**
SonarQube is the centralised quality dashboard for the whole team. It tracks whether
quality is improving or degrading over time, catches issues that single-pass tools miss
(e.g., cross-method taint analysis for injection), enforces coverage minimums, and blocks
merges via Quality Gate (Section 12.8). For a production application, it is the primary
evidence that the codebase meets a defined quality standard.

**How to apply:**

**Step 1 — Run a local SonarQube server (Docker):**
```bash
docker run -d \
  --name sonarqube \
  -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  sonarqube:community

# Open http://localhost:9000
# Default login: admin / admin  (change immediately)
```

**Step 2 — Create a project and generate a token:**
1. Log in at `http://localhost:9000`
2. Create a project named `issue-tracker`
3. Under **Account > Security**, generate an analysis token
4. Note the token: `squ_xxxxxxxxxxxxxxxxxxxxx`

**Step 3 — Add sonar properties to each service:**

Create `auth-service/sonar-project.properties`:
```properties
sonar.projectKey=issue-tracker-auth
sonar.projectName=Issue Tracker - Auth Service
sonar.projectVersion=0.0.1
sonar.sources=src/main/java
sonar.tests=src/test/java
sonar.java.binaries=target/classes
sonar.language=java
sonar.sourceEncoding=UTF-8
```

Create `issue-service/sonar-project.properties`:
```properties
sonar.projectKey=issue-tracker-issues
sonar.projectName=Issue Tracker - Issue Service
sonar.projectVersion=0.0.1
sonar.sources=src/main/java
sonar.tests=src/test/java
sonar.java.binaries=target/classes
sonar.language=java
sonar.sourceEncoding=UTF-8
```

Create `frontend-service/sonar-project.properties`:
```properties
sonar.projectKey=issue-tracker-frontend
sonar.projectName=Issue Tracker - Frontend
sonar.projectVersion=0.0.1
sonar.sources=src
sonar.exclusions=node_modules/**,build/**,**/*.test.js
sonar.javascript.lcov.reportPaths=coverage/lcov.info
```

**Step 4 — Run analysis:**
```bash
# Build first (SonarQube needs compiled classes)
cd auth-service && ./mvnw clean package -DskipTests -B

# Run Sonar analysis via Maven
./mvnw sonar:sonar \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login=squ_xxxxxxxxxxxxxxxxxxxxx

# Same for issue-service and api-gateway
cd ../issue-service && ./mvnw clean package -DskipTests -B
./mvnw sonar:sonar \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login=squ_xxxxxxxxxxxxxxxxxxxxx

# Frontend
cd ../frontend-service
npm run test -- --coverage --watchAll=false
npx sonar-scanner \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login=squ_xxxxxxxxxxxxxxxxxxxxx
```

**What SonarQube will specifically flag in this project:**

| Issue | Location | Severity | Why it matters |
|---|---|---|---|
| Missing unit tests | All services | Major | JPA entities, JWT parsing logic, and controller layer have no test coverage |
| `ddl-auto=update` in prod | `application-prod.properties` | Major | Schema changes applied silently; use Flyway/Liquibase instead |
| `@Value` secret injection | `JwtService.java`, `JwtUtil.java`, `SecurityConfig.java` | Minor | Should be `@ConfigurationProperties` with validation |
| Hard-coded `"HmacSHA256"` string | `api-gateway/SecurityConfig.java` | Info | Use a constant |
| Mutable public fields in DTOs | `*DTO.java` | Minor | DTOs should be immutable records |

---

### 12.8 Quality Gate — Merge/Deploy Gate

**What it is:**
A Quality Gate is a set of conditions defined in SonarQube that must all pass before a
build is considered healthy. If any condition fails, the gate reports `FAILED`, and the
CI pipeline halts — the pull request cannot be merged. Quality Gates turn SonarQube from
an advisory tool into an enforcing control.

**SDLC value:**
Without a Quality Gate, developers can see SonarQube findings and ignore them. With a
Quality Gate, every new finding that crosses a severity threshold is a build-breaker.
This is the mechanism that maintains a "clean as you code" policy: new code must not
introduce regressions in quality or security.

**How to configure in SonarQube:**

Navigate to **Quality Gates** in the SonarQube UI and create a gate named
`issue-tracker-gate` with the following conditions:

| Metric | Operator | Threshold | Rationale |
|---|---|---|---|
| New Blocker Issues | greater than | 0 | Zero tolerance for blockers on new code |
| New Critical Issues | greater than | 0 | Zero tolerance for critical issues on new code |
| New Bugs | greater than | 0 | No new bugs introduced |
| New Vulnerabilities | greater than | 0 | No new security vulnerabilities |
| New Security Hotspots Reviewed | less than | 100% | All hotspots must be reviewed |
| Coverage on New Code | less than | 70% | New code must have ≥70% test coverage |
| Duplicated Lines on New Code | greater than | 3% | Limit copy-paste |

Assign this gate to the project: **Project Settings → Quality Gate → `issue-tracker-gate`**.

**Check gate status from CI:**
```bash
# After sonar:sonar completes, poll the gate result (replace PROJECT_KEY and TOKEN)
STATUS=$(curl -s \
  -u squ_xxxxxxxxxxxxxxxxxxxxx: \
  "http://localhost:9000/api/qualitygates/project_status?projectKey=issue-tracker-auth" \
  | jq -r '.projectStatus.status')

echo "Quality Gate: $STATUS"
[ "$STATUS" = "OK" ] || { echo "Quality Gate FAILED — blocking pipeline"; exit 1; }
```

**Full CI pipeline sequence (GitHub Actions skeleton):**

```yaml
name: CI Pipeline

on: [push, pull_request]

jobs:
  pipeline:
    runs-on: ubuntu-latest
    steps:
      # 1. Gitleaks
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@v2

      # 2 & 4. Checkstyle + Build
      - uses: actions/setup-java@v4
        with: { java-version: '17', distribution: 'temurin' }
      - name: Build auth-service (checkstyle + package)
        run: ./mvnw clean package -DskipTests -B
        working-directory: auth-service
      - name: Build issue-service
        run: ./mvnw clean package -DskipTests -B
        working-directory: issue-service
      - name: Build api-gateway
        run: ./mvnw clean package -DskipTests -B
        working-directory: api-gateway

      # 3. Semgrep
      - name: Semgrep SAST
        run: |
          pip install semgrep
          semgrep --config p/spring-security --config p/java \
                  --config p/javascript --config p/react \
                  --error .

      # 6. Lint
      - uses: actions/setup-node@v4
        with: { node-version: '18' }
      - name: Install frontend deps
        run: npm ci
        working-directory: frontend-service
      - name: ESLint
        run: npm run lint
        working-directory: frontend-service

      # 9. NVD Check (SCA — after build so JARs exist)
      - name: NVD Dependency-Check – auth-service
        run: ./mvnw dependency-check:check -Denv.NVD_API_KEY=${{ secrets.NVD_API_KEY }}
        working-directory: auth-service
      - name: NVD Dependency-Check – issue-service
        run: ./mvnw dependency-check:check -Denv.NVD_API_KEY=${{ secrets.NVD_API_KEY }}
        working-directory: issue-service
      - name: NVD Dependency-Check – api-gateway
        run: ./mvnw dependency-check:check -Denv.NVD_API_KEY=${{ secrets.NVD_API_KEY }}
        working-directory: api-gateway
      - name: npm audit (frontend)
        run: npm audit --audit-level=high
        working-directory: frontend-service

      # 7 & 8. SonarQube + Quality Gate
      - name: SonarQube analysis
        run: |
          ./mvnw sonar:sonar -Dsonar.host.url=${{ secrets.SONAR_HOST }} \
            -Dsonar.login=${{ secrets.SONAR_TOKEN }}
        working-directory: auth-service
      - name: Check Quality Gate
        run: |
          STATUS=$(curl -s -u ${{ secrets.SONAR_TOKEN }}: \
            "${{ secrets.SONAR_HOST }}/api/qualitygates/project_status?projectKey=issue-tracker-auth" \
            | jq -r '.projectStatus.status')
          [ "$STATUS" = "OK" ] || exit 1

  # 5. DAST — runs after deploy to staging
  dast:
    needs: pipeline
    runs-on: ubuntu-latest
    steps:
      - name: OWASP ZAP Baseline Scan
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: ${{ secrets.STAGING_URL }}
          fail_action: true
```

---

### 12.9 NVD Check — Dependency Vulnerability Scanning

**What it is:**
NVD Check (also called Software Composition Analysis, SCA) scans every third-party
library your project depends on against the **National Vulnerability Database** (NVD)
maintained by NIST. Each known vulnerability is catalogued as a **CVE** (Common
Vulnerabilities and Exposures) and scored on the **CVSS** (Common Vulnerability Scoring
System) scale from 0 to 10. The primary Maven tool is the
**OWASP Dependency-Check plugin**; the Node.js equivalent is **`npm audit`**.

Unlike SAST (which reads your code), NVD Check reads your _dependencies_ — the compiled
JARs and npm packages you pull in from the internet. A vulnerability in a dependency you
did not write is just as exploitable as one in your own code.

**CVSS Severity Reference:**

| CVSS Score | Severity | Recommended action |
|---|---|---|
| 9.0 – 10.0 | **Critical** | Block build immediately, patch before any merge |
| 7.0 – 8.9 | **High** | Block build, upgrade or suppress with justification |
| 4.0 – 6.9 | **Medium** | Warn in CI; track and remediate within sprint |
| 0.1 – 3.9 | **Low** | Informational; include in backlog |

**SDLC value:**
Third-party dependencies account for 70–90% of modern application code. Every package
you import inherits its entire transitive dependency tree — a single vulnerable transitive
dependency can expose your running application to remote code execution or data
exfiltration. NVD Check runs after the Maven build (so all JARs are resolved) and before
any deployment, catching known CVEs before they reach staging or production.

Specific dependency risks in this project:

| Dependency | Version | Why it matters |
|---|---|---|
| `jjwt-api / jjwt-impl` | 0.12.5 | JWT library — any parsing vulnerability compromises all authentication |
| `mysql-connector-j` | latest | JDBC driver — SQL injection or deserialization CVEs are critical |
| `modelmapper` | 3.2.0 | Object mapping — deserialization vulnerabilities are a known class |
| `spring-boot-starter-*` | 3.4.1 / 4.0.1 | Large transitive tree — Spring regularly patches CVEs |
| `react-scripts` | 5.0.1 | CRA has many transitive npm deps with known moderate vulnerabilities |
| `axios` | ^1.13.4 | HTTP client — SSRF and prototype pollution CVEs have occurred in past versions |

---

**How to apply — Java services (OWASP Dependency-Check Maven plugin):**

**Step 1 — Get an NVD API key (free, required for fast data download):**

> Since 2023, NIST requires an API key for NVD data access without strict rate limiting.
> Without one, the initial database download can take 30+ minutes.

1. Go to https://nvd.nist.gov/developers/request-an-api-key
2. Register with your email address
3. You will receive a key like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
4. Store it as an environment variable: `export NVD_API_KEY=<your-key>`
5. In CI, store it as a secret: `NVD_API_KEY` in GitHub Secrets / Jenkins credentials

**Step 2 — Add the plugin to each Java service's `pom.xml`:**

Add inside `<build><plugins>` in `auth-service/pom.xml`, `issue-service/pom.xml`,
and `api-gateway/pom.xml`:

```xml
<plugin>
    <groupId>org.owasp</groupId>
    <artifactId>dependency-check-maven</artifactId>
    <version>10.0.3</version>
    <configuration>
        <!-- NVD API key for fast CVE data download -->
        <nvdApiKey>${env.NVD_API_KEY}</nvdApiKey>

        <!-- Fail the build if any dependency has CVSS score >= 7 (High/Critical) -->
        <failBuildOnCVSS>7</failBuildOnCVSS>

        <!-- Report formats: HTML for humans, JSON for CI parsing -->
        <formats>
            <format>HTML</format>
            <format>JSON</format>
        </formats>

        <!-- Skip dependencies in test scope -->
        <skipTestScope>true</skipTestScope>

        <!-- Path to suppression file for accepted false positives -->
        <suppressionFile>dependency-check-suppressions.xml</suppressionFile>

        <!-- Cache NVD data locally to speed up subsequent runs -->
        <dataDirectory>${user.home}/.owasp/dependency-check-data</dataDirectory>
    </configuration>
    <executions>
        <execution>
            <id>nvd-check</id>
            <phase>verify</phase>
            <goals>
                <goal>check</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

**Step 3 — Run the scan:**

```bash
# Run against auth-service (downloads NVD data on first run, ~2-5 min with API key)
cd auth-service
export NVD_API_KEY=<your-key>
./mvnw dependency-check:check

# Report is written to:
# target/dependency-check-report.html  ← open in browser
# target/dependency-check-report.json  ← for CI parsing

# Same for issue-service and api-gateway
cd ../issue-service && ./mvnw dependency-check:check
cd ../api-gateway   && ./mvnw dependency-check:check
```

Or run it as part of the full Maven lifecycle (bound to `verify` phase):
```bash
./mvnw clean verify   # runs: compile → test → package → dependency-check
```

**Step 4 — Create a suppression file for accepted false positives:**

Some CVEs are flagged against libraries that only affect configurations you do not use.
Document these with a suppression file so they do not block CI, with a mandatory
justification note.

Create `auth-service/dependency-check-suppressions.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<suppressions xmlns="https://jeremylong.github.io/DependencyCheck/dependency-suppression.1.3.xsd">

    <!--
        Example: A CVE in H2 in-memory database (pulled in by Spring Boot test scope).
        We only use H2 in tests and do not expose it to the network.
        Suppression expires on a set date, forcing periodic review.
    -->
    <!--
    <suppress until="2025-06-01Z">
        <notes>H2 console enabled CVE — only present in test scope, not in production JAR.</notes>
        <cve>CVE-2022-45868</cve>
    </suppress>
    -->

</suppressions>
```

> Every suppression **must** include a `<notes>` justification and an `until=` expiry
> date. Suppressions without expiry dates accumulate silently and hide real vulnerabilities
> over time.

---

**How to apply — React frontend (`npm audit`):**

`npm audit` queries the npm Advisory Database (which mirrors NVD data) and reports CVEs
in all installed packages and their transitive dependencies.

```bash
cd frontend-service

# Install deps first
npm install

# Audit — exit non-zero if any HIGH or CRITICAL vulnerabilities found
npm audit --audit-level=high

# Show full report including moderate
npm audit

# Generate JSON report for CI upload
npm audit --json > npm-audit-report.json
```

Auto-fix vulnerabilities where a non-breaking upgrade exists:
```bash
npm audit fix

# For major-version upgrades (review output carefully before committing)
npm audit fix --force
```

> `react-scripts@5.0.1` carries several known moderate npm advisories in its transitive
> dependencies (e.g., `nth-check`, `postcss`). These are typically inside the build
> toolchain only and do not ship to production — suppress them with `--audit-level=high`
> to avoid blocking CI on non-runtime vulnerabilities.

---

**How to apply — Aggregate scan across all services:**

Run a single dependency-check report covering all four services from the repo root
using the CLI (rather than Maven):

```bash
# Install the CLI
wget https://github.com/jeremylong/DependencyCheck/releases/download/v10.0.3/dependency-check-10.0.3-release.zip
unzip dependency-check-10.0.3-release.zip

# Scan all JAR outputs + node_modules in one pass
./dependency-check/bin/dependency-check.sh \
  --project "issue-tracker-v1" \
  --scan   "auth-service/target/*.jar" \
  --scan   "issue-service/target/*.jar" \
  --scan   "api-gateway/target/*.jar" \
  --scan   "frontend-service/node_modules" \
  --nvdApiKey  "$NVD_API_KEY" \
  --failOnCVSS 7 \
  --format     HTML \
  --format     JSON \
  --out        ./nvd-report/
```

The HTML report (`nvd-report/dependency-check-report.html`) shows each vulnerable
dependency, the CVE IDs, CVSS scores, affected versions, and the fixed version to
upgrade to.

---

### Security Pipeline — Quick Reference

| # | Tool | Stage | Scope | Blocks merge? |
|---|---|---|---|---|
| 1 | **Gitleaks** | Pre-commit / CI | Git history + diff | Yes |
| 2 | **Checkstyle** | CI — validate phase | Java source style | Yes |
| 3 | **Semgrep** | CI — SAST | Java + JS/React security patterns | Yes |
| 4 | **Maven Build** | CI — compile | All three Spring Boot services | Yes |
| 5 | **DAST Audit** | Post-deploy staging | Running app over HTTP | Blocks promotion |
| 6 | **Lint (ESLint + SpotBugs)** | CI | React JS + Java bytecode | Yes |
| 7 | **SonarQube** | CI — analysis | All services + frontend | Yes |
| 8 | **Quality Gate** | CI — gate | SonarQube metrics threshold | Yes |
| 9 | **NVD Check (SCA)** | CI — after build | Third-party JARs + npm packages | Yes (CVSS ≥ 7) |
