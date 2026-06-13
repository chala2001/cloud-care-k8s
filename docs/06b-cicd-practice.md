# 06b — CI/CD Practice: Every Workflow File, Every Line

> **Read 06a first.** This doc writes every GitHub Actions workflow file with
> every line explained — covering dev deploy, prod deploy, and Terraform infra changes.
> No AWS costs — GitHub Actions runners are free for public repos.

---

## 1. Create the workflows directory

```bash
mkdir -p /home/chalaka/cloud-care-both/cloud-care-k8s/.github/workflows
```

---

## 2. Branch strategy — dev vs prod

```
Branch: dev   → push code → build image → deploy to EKS dev namespace   (values-dev.yaml)
Branch: main  → push code → build image → deploy to EKS prod namespace  (values-prod.yaml)

Branch: any   → change terraform/ files → terraform plan (show what would change, no apply)
Branch: main  → change terraform/ files → terraform apply (actually apply the change)
```

So you will have these workflow files:
```
.github/workflows/
  deploy-patient-service.yml       ← handles both dev and prod branches
  deploy-appointment-service.yml
  deploy-audit-service.yml
  deploy-notification-service.yml
  terraform.yml                    ← handles infrastructure changes
```

---

## 3. Service deploy workflow — dev + prod in one file

One file handles both branches. The branch name determines which namespace
and values file to use. We write patient-service in full; the other 3 differ
only in the env vars shown in section 4.

### `.github/workflows/deploy-patient-service.yml`

```yaml
name: Deploy patient-service

on:
  push:
    branches:
      - main    # prod deploy
      - dev     # dev deploy
    paths:
      - "services/patient-service/**"
      - ".github/workflows/deploy-patient-service.yml"
      # only runs when patient-service code or this workflow file changes
      # pushing to appointment-service code does NOT trigger this

env:
  AWS_REGION: ap-south-1
  ECR_REPOSITORY: cloudcare-k8s-patient-service
  SERVICE_DIR: services/patient-service
  HELM_CHART: helm/patient-service
  HELM_RELEASE: patient-service

jobs:

  # ── Job 1: Build and push Docker image ──────────────────────────────────────
  build:
    name: Build & Push to ECR
    runs-on: ubuntu-latest

    permissions:
      id-token: write    # REQUIRED for OIDC — allows workflow to request a JWT
      contents: read

    outputs:
      image_tag: ${{ steps.tag.outputs.tag }}

    steps:

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set image tag
        id: tag
        run: echo "tag=${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
        # first 7 chars of the git commit SHA — immutable, unique per commit
        # same image tag used for both dev and prod deploys of the same commit

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::670794226080:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push Docker image
        env:
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          TAG: ${{ steps.tag.outputs.tag }}
        run: |
          docker build \
            -t $REGISTRY/$ECR_REPOSITORY:$TAG \
            -t $REGISTRY/$ECR_REPOSITORY:latest \
            $SERVICE_DIR
          docker push $REGISTRY/$ECR_REPOSITORY:$TAG
          docker push $REGISTRY/$ECR_REPOSITORY:latest
          # both dev and prod use the SAME image from ECR
          # environment differences come from Helm values files, not the image

  # ── Job 2: Deploy to dev namespace (only on dev branch) ─────────────────────
  deploy-dev:
    name: Deploy to dev
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/dev'
    # if: condition — this job ONLY runs when the triggering branch is "dev"
    # on a push to main, this job is skipped entirely

    permissions:
      id-token: write
      contents: read

    steps:

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::670794226080:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure kubectl
        run: aws eks update-kubeconfig --name cloudcare-k8s --region $AWS_REGION

      - name: Deploy to dev namespace
        env:
          TAG: ${{ needs.build.outputs.image_tag }}
          REGISTRY: 670794226080.dkr.ecr.ap-south-1.amazonaws.com
        run: |
          helm upgrade --install $HELM_RELEASE $HELM_CHART \
            --namespace dev \
            --create-namespace \
            -f $HELM_CHART/values-dev.yaml \
            --set image.repository=$REGISTRY/$ECR_REPOSITORY \
            --set image.tag=$TAG \
            --set image.pullPolicy=Always \
            --wait --timeout 5m
          # -f values-dev.yaml: 1 replica, no HPA, plain K8s secrets, DEBUG logging
          # --set image.pullPolicy=Always: forces ECR image pull even if tag exists on node
          # this ensures the dev pod always runs the latest pushed image

      - name: Verify dev deploy
        run: |
          kubectl rollout status deployment/$HELM_RELEASE -n dev
          kubectl get pods -n dev -l app=$HELM_RELEASE

  # ── Job 3: Deploy to prod namespace (only on main branch) ───────────────────
  deploy-prod:
    name: Deploy to prod
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/main'
    # only runs on pushes to main — dev branch pushes skip this job

    permissions:
      id-token: write
      contents: read

    steps:

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::670794226080:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure kubectl
        run: aws eks update-kubeconfig --name cloudcare-k8s --region $AWS_REGION

      - name: Deploy to prod namespace
        env:
          TAG: ${{ needs.build.outputs.image_tag }}
          REGISTRY: 670794226080.dkr.ecr.ap-south-1.amazonaws.com
        run: |
          helm upgrade --install $HELM_RELEASE $HELM_CHART \
            --namespace prod \
            --create-namespace \
            -f $HELM_CHART/values-prod.yaml \
            --set image.repository=$REGISTRY/$ECR_REPOSITORY \
            --set image.tag=$TAG \
            --wait --timeout 5m
          # -f values-prod.yaml: 2 replicas, HPA enabled, ESO secrets, WARNING logging

      - name: Verify prod deploy
        run: |
          kubectl rollout status deployment/$HELM_RELEASE -n prod
          kubectl get pods -n prod -l app=$HELM_RELEASE
```

---

## 4. The other 3 service workflows (env var diff only)

Only these 4 env vars change per service. Everything else is identical.

| Workflow file | ECR_REPOSITORY | SERVICE_DIR | HELM_CHART | HELM_RELEASE |
|---|---|---|---|---|
| `deploy-appointment-service.yml` | `cloudcare-k8s-appointment-service` | `services/appointment-service` | `helm/appointment-service` | `appointment-service` |
| `deploy-audit-service.yml` | `cloudcare-k8s-audit-service` | `services/audit-service` | `helm/audit-service` | `audit-service` |
| `deploy-notification-service.yml` | `cloudcare-k8s-notification-service` | `services/notification-service` | `helm/notification-service` | `notification-service` |

Also change the `paths:` trigger to match each service directory.

---

## 5. Terraform workflow — infra changes

This handles all infrastructure changes: VPC, EKS, ECR, RDS, IAM roles.

### `.github/workflows/terraform.yml`

```yaml
name: Terraform Infrastructure

on:
  push:
    branches:
      - main
      - dev
    paths:
      - "terraform/**"                  # any change inside terraform/ triggers this
      - ".github/workflows/terraform.yml"
  pull_request:
    paths:
      - "terraform/**"
      - ".github/workflows/terraform.yml"
    # on a Pull Request: run terraform plan (preview only — no apply)
    # on merge to main: run terraform apply

env:
  AWS_REGION: ap-south-1
  TF_STATE_BUCKET: cloudcare-k8s-tfstate-670794226080

jobs:

  # ── Job 1: Plan and apply eks stack ──────────────────────────────────────────
  eks:
    name: EKS Stack — ${{ github.event_name == 'pull_request' && 'Plan' || 'Apply' }}
    # job name shows "Plan" on PRs and "Apply" on pushes — easier to read in GitHub UI
    runs-on: ubuntu-latest

    permissions:
      id-token: write
      contents: read
      pull-requests: write    # needed to post terraform plan output as a PR comment

    defaults:
      run:
        working-directory: terraform/eks    # all run: steps execute from this directory

    steps:

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"    # pin version — prevents surprise behaviour from upgrades

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::670794226080:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}
          # the github_deploy role needs additional permissions for Terraform:
          # ec2:*, eks:*, iam:*, ecr:* — add these to the role policy in oidc.tf

      - name: Terraform Init
        run: terraform init
        # downloads providers, connects to S3 backend for state
        # uses backend.tf: bucket=cloudcare-k8s-tfstate-670794226080, key=eks/terraform.tfstate

      - name: Terraform Validate
        run: terraform validate
        # checks HCL syntax and internal consistency — no AWS calls needed
        # catches typos and missing required arguments before plan

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        # -no-color: plain text output (GitHub comments don't render ANSI colours)
        # -out=tfplan: saves the plan to a file so apply uses the exact same plan
        continue-on-error: true
        # continue-on-error: plan errors are shown as a PR comment, not a silent failure

      - name: Post plan as PR comment
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const output = `#### EKS Stack Plan
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });
        # posts the plan output directly on the PR so you can review before merging
        # you see exactly what will change in AWS before clicking "Merge"

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        # only apply on direct pushes to main (i.e. after PR is merged)
        # NEVER apply on PRs — we only plan on PRs
        run: terraform apply -auto-approve tfplan
        # -auto-approve: skip the interactive "yes" prompt (CI can't type)
        # tfplan: uses the exact plan file from the plan step — no surprises

  # ── Job 2: Plan and apply platform stack (depends on eks) ────────────────────
  platform:
    name: Platform Stack — ${{ github.event_name == 'pull_request' && 'Plan' || 'Apply' }}
    runs-on: ubuntu-latest
    needs: eks
    # platform depends on eks outputs (VPC IDs, cluster name)
    # wait for eks job to finish before planning/applying platform

    permissions:
      id-token: write
      contents: read
      pull-requests: write

    defaults:
      run:
        working-directory: terraform/platform

    steps:

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::670794226080:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        continue-on-error: true

      - name: Post plan as PR comment
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const output = `#### Platform Stack Plan
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve tfplan
```

---

## 6. Extra IAM permissions needed for the github_deploy role

The `github_deploy` role in `oidc.tf` currently only has ECR push + EKS describe.
Terraform needs much broader permissions. Add this to `terraform/eks/oidc.tf`:

```hcl
resource "aws_iam_role_policy" "github_terraform" {
  name = "cloudcare-k8s-github-terraform-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:*", "eks:*", "ecr:*", "iam:*",
                    "rds:*", "secretsmanager:*", "s3:*",
                    "dynamodb:*", "elasticloadbalancing:*"]
        Resource = "*"
        # broad permissions for Terraform to manage all infrastructure
        # in a real project you'd scope these more tightly
        # for a learning project this is acceptable
      }
    ]
  })
}
```

---

## 7. Full flow visualised

```
Developer:
  feature work → push to dev branch
        │
        ▼
GitHub Actions:
  deploy-patient-service.yml triggered (paths match)
  build job: docker build → push to ECR with tag abc1234
  deploy-dev job: helm upgrade patient-service -f values-dev.yaml --namespace dev
        │
        ▼
EKS dev namespace:
  1 replica, DEBUG logs, plain K8s secrets, no HPA

Developer:
  ready to release → open Pull Request: dev → main
        │
        ▼
GitHub Actions:
  terraform.yml triggered (if terraform/ files changed in the PR)
  eks job: terraform plan → posts plan output as PR comment
  platform job: terraform plan → posts plan output as PR comment
  You review the plan on the PR — see exactly what AWS will change

Developer:
  merge the PR
        │
        ▼
GitHub Actions:
  deploy-patient-service.yml triggered on main
  build job: same image already in ECR — skipped if no code changes
  deploy-prod job: helm upgrade patient-service -f values-prod.yaml --namespace prod
  terraform.yml triggered (if terraform changed): terraform apply eks → terraform apply platform
        │
        ▼
EKS prod namespace:
  2 replicas, HPA enabled, ESO secrets from Secrets Manager, WARNING logs
```

---

## ✅ Checkpoint — done when:

- [ ] 5 workflow files created in `.github/workflows/`
- [ ] Service workflows have `deploy-dev` (if branch=dev) and `deploy-prod` (if branch=main) jobs
- [ ] `terraform.yml` has separate eks and platform jobs, plan on PR, apply on main
- [ ] `oidc.tf` updated: your GitHub username + Terraform IAM permissions
- [ ] You can explain: what happens when you push to the `dev` branch?
- [ ] You can explain: what happens when you open a PR with Terraform changes?
- [ ] You can explain: why does the platform job have `needs: eks`?
- [ ] You can explain: why is `terraform apply` blocked on PRs?

Next: **[07a — Secrets Concepts](07a-secrets-concepts.md)** — IRSA and External
Secrets Operator so pods get AWS credentials without stored keys.
