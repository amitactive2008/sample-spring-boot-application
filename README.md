What was created
helm/issue-tracker/
├── Chart.yaml                     # chart metadata
├── .helmignore
├── values.yaml                    # kind defaults (ready to use)
├── values-prod.yaml               # prod overrides (ECR images, RDS, ALB)
└── templates/
    ├── _helpers.tpl               # reusable snippets (labels, jdbcUrl, mysqlHost, ingressPaths)
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── secrets.yaml               # api-gateway-secrets, auth-service-secrets, issue-service-secrets
    ├── configmaps.yaml            # auth-service-config, issue-service-config
    ├── ingress.yaml               # nginx (kind) or ALB (prod) — controlled by values
    ├── mysql.yaml                 # Deployment + Service + PVC (skipped when mysql.enabled=false)
    ├── api-gateway.yaml
    ├── auth-service.yaml          # includes APP_ADMIN_EMAIL/PASSWORD fix
    ├── issue-service.yaml         # includes PVC mount
    └── frontend-service.yaml

scripts/helm-deploy.sh             # automation script
One-command deploy to kind
brew install kind kubectl helm
./scripts/helm-deploy.sh
App at http://localhost:8080 | Admin: admin@example.com / Admin1234!
Key script subcommands
./scripts/helm-deploy.sh            # full: create cluster + build + install
./scripts/helm-deploy.sh upgrade    # rebuild images + helm upgrade only
./scripts/helm-deploy.sh lint       # dry-run without touching the cluster
./scripts/helm-deploy.sh teardown   # delete the kind cluster


Prod deploy (once Terraform has provisioned infra)
helm upgrade --install issue-tracker helm/issue-tracker \
  --namespace issue-app --create-namespace \
  -f helm/issue-tracker/values-prod.yaml \
  --set jwt.secret="$JWT_SECRET" \
  --set db.host="$RDS_ENDPOINT" \
  --set db.username="$DB_USERNAME" \
  --set db.password="$DB_PASSWORD" \
  --set admin.email="$ADMIN_EMAIL" \
  --set admin.password="$ADMIN_PASSWORD" \
  --set apiGateway.image.tag="$GIT_SHA" \
  --set authService.image.tag="$GIT_SHA" \
  --set issueService.image.tag="$GIT_SHA" \
  --set frontendService.image.tag="$GIT_SHA"
