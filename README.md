Prerequisites
Install these on your laptop:
Tool	Version	Install
Docker Desktop	Latest	https://docs.docker.com/desktop (https://docs.docker.com/desktop)
Docker Compose	v2 (bundled with Docker Desktop)	—
That's it. Java, Maven, and Node are not needed — they run inside the containers.
Steps
1. Copy the env file
cp .env.example .env
Edit .env if you want to change passwords. The defaults work fine locally.
2. Build and start all services
docker-compose up --build
First run takes ~5–10 minutes (Maven downloads dependencies, Node installs packages). Subsequent starts are fast.
3. Open the app
URL	What
http://localhost:3000	React frontend
http://localhost:8096	API Gateway (direct)
http://localhost:8097	Auth service (direct)
http://localhost:8098	Issue service (direct)
4. Log in
Use the seeded admin account:
- Email: admin@example.com
- Password: Admin1234!
(These come from APP_ADMIN_EMAIL / APP_ADMIN_PASSWORD in .env)
Useful commands
# Stop everything
docker-compose down

# Stop and wipe the database volume (fresh start)
docker-compose down -v

# View logs for one service
docker-compose logs -f auth-service

# Restart a single service after a code change
docker-compose up --build auth-service
How it wires together locally
Browser
  └── http://localhost:3000   (frontend dev server)
        └── axios calls → http://localhost:8096  (api-gateway)
              ├── /auth/**  → auth-service:8097  (Docker internal DNS)
              └── /issues/** → issue-service:8098
                    └── Both read from MySQL:3306 (Docker internal)
The JWT secret is shared across all three Java services via the JWT_SECRET env var in .env.
Known limitation
Email (AWS SES) is disabled locally (MAIL_ENABLED=false). Welcome emails on registration are silently skipped — this is intentional since SES credentials are not needed for local dev.
