Prerequisites
brew install kind kubectl
# Docker Desktop must be running
One-command deploy
./scripts/kind-deploy.sh
The script does everything automatically. Once done, open http://localhost:8080.
Default admin: admin@example.com / Admin1234!
What was created
kubernetes/environments/kind/
├── kind-cluster.yaml          # kind cluster config (port 8080→80)
├── kustomization.yaml         # overlay — selectively pulls from base
├── secrets.yaml               # plain Secrets (replaces ESO + AWS Secrets Manager)
├── ingress.yaml               # nginx ingress with /api prefix-strip
├── mysql/
│   ├── deployment.yaml        # MySQL 8.0 in-cluster (replaces AWS RDS)
│   ├── service.yaml
│   └── pvc.yaml               # standard StorageClass (kind built-in)
└── patches/
    ├── configmap-auth.yaml    # DB URL → mysql:3306; MAIL_ENABLED=false
    ├── configmap-issue.yaml   # DB URL → mysql:3306
    ├── pvc-storageclass.yaml  # gp2 → standard
    ├── deployment-api-gateway.yaml    # CORS origin + imagePullPolicy: Never
    ├── deployment-auth-service.yaml   # admin seed creds + imagePullPolicy: Never
    ├── deployment-issue-service.yaml  # imagePullPolicy: Never
    └── deployment-frontend-service.yaml # imagePullPolicy: Never

scripts/kind-deploy.sh         # automation script
What each piece solves
Problem
No AWS ECR
No AWS RDS
No External Secrets Operator
AWS ALB Ingress won't work
gp2 StorageClass (AWS-only)
APP_ADMIN_EMAIL/PASSWORD missing from base Deployment
Images pulled from registry
Tear down
./scripts/kind-deploy.sh teardown
