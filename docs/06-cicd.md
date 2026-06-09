# 06 — CI/CD Pipelines

> **Goal of this doc:** write a GitHub Actions pipeline for each microservice that
> runs tests, builds and pushes a Docker image tagged with the git SHA, deploys
> to dev automatically, and deploys to prod only after manual approval.

---

## 1. The Core Principle: One Pipeline per Service

In CloudCare v1, one `backend.yml` workflow handled the entire monolith.
In CloudCare-K8s, each service has its own workflow. Changing `patient-service`
triggers only `patient-service.yml` — the other three services keep running
undisturbed.

```
.github/workflows/
├── patient-service.yml      ← triggers only on changes to services/patient-service/**
├── appointment-service.yml  ← triggers only on changes to services/appointment-service/**
├── audit-service.yml
├── notification-service.yml
├── frontend.yml
└── terraform.yml
```

This is **independent deployability** — the defining feature of microservices.

---

## 2. Immutable Image Tags (git SHA)

In v1 we used `:latest` as the Docker image tag. That's dangerous:

- `:latest` from two different deploys could be different images.
- You can't tell which code is running in production by looking at the image tag.
- Rolling back means re-tagging and re-pushing.

In v2 we tag every image with the **git commit SHA**:
```
123456789.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service:a3f8b2c
```

Now:
- Every build produces a unique, traceable image.
- You can see exactly which commit is running in prod.
- Rollback = `helm rollback patient-service 1 -n prod` (one command, no re-tagging).

> 🧠 **This is a critical production practice.** Interviewers will ask about it.
> The answer is: "We use the git SHA as the image tag so every image is immutable
> and traceable to a specific commit."

---

## 3. The Pipeline Structure

Every service pipeline follows this four-job structure:

```
push to main (changes in services/patient-service/**)
  │
  ▼
job: test
  └── pytest services/patient-service/tests/
  │
  ▼ (needs: test)
job: build-push
  ├── Authenticate to AWS via OIDC (no stored keys)
  ├── docker build -t $ECR_REPO:${{ github.sha }}
  └── docker push $ECR_REPO:${{ github.sha }}
  │
  ▼ (needs: build-push, only on push to main)
job: deploy-dev
  └── helm upgrade --install patient-service ... --set image.tag=${{ github.sha }} -n dev
  │
  ▼ (needs: deploy-dev)
job: deploy-prod
  ├── environment: production   ← manual approval gate in GitHub
  └── helm upgrade --install patient-service ... --set image.tag=${{ github.sha }} -n prod
```

---

## 4. patient-service.yml

`.github/workflows/patient-service.yml`:
```yaml
name: patient-service

on:
  push:
    branches: [main]
    paths:
      - "services/patient-service/**"
      - ".github/workflows/patient-service.yml"
  pull_request:
    paths:
      - "services/patient-service/**"

# Prevent concurrent runs — two deploys at once can cause race conditions
concurrency:
  group: patient-service-${{ github.ref }}
  cancel-in-progress: true

env:
  AWS_REGION: ap-south-1
  ECR_REPO: ${{ vars.AWS_ACCOUNT_ID }}.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service
  SERVICE_DIR: services/patient-service

jobs:
  test:
    name: Run Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: |
          cd ${{ env.SERVICE_DIR }}
          pip install -r requirements.txt
          pip install pytest httpx

      - name: Run tests
        run: |
          cd ${{ env.SERVICE_DIR }}
          pytest tests/ -v

  build-push:
    name: Build and Push to ECR
    runs-on: ubuntu-latest
    needs: test           # only runs if tests pass
    # Only build on push to main — not on PRs
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'

    permissions:
      id-token: write    # required for OIDC
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push Docker image
        run: |
          cd ${{ env.SERVICE_DIR }}
          docker build -t ${{ env.ECR_REPO }}:${{ github.sha }} .
          docker push ${{ env.ECR_REPO }}:${{ github.sha }}
          # Also tag as latest for convenience (but deploy always uses SHA)
          docker tag ${{ env.ECR_REPO }}:${{ github.sha }} ${{ env.ECR_REPO }}:latest
          docker push ${{ env.ECR_REPO }}:latest

  deploy-dev:
    name: Deploy to Dev
    runs-on: ubuntu-latest
    needs: build-push
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'

    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure kubectl
        run: aws eks update-kubeconfig --name cloudcare-k8s --region ${{ env.AWS_REGION }}

      - name: Install Helm
        uses: azure/setup-helm@v4

      - name: Deploy to dev namespace
        run: |
          helm upgrade --install patient-service ./helm/patient-service \
            -f helm/patient-service/values-dev.yaml \
            --set image.repository=${{ env.ECR_REPO }} \
            --set image.tag=${{ github.sha }} \
            --namespace dev \
            --create-namespace \
            --wait \
            --timeout 3m

      - name: Verify deployment
        run: kubectl rollout status deployment/patient-service -n dev --timeout=2m

  deploy-prod:
    name: Deploy to Prod
    runs-on: ubuntu-latest
    needs: deploy-dev
    # environment: production creates a manual approval gate in GitHub
    environment: production

    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-github-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure kubectl
        run: aws eks update-kubeconfig --name cloudcare-k8s --region ${{ env.AWS_REGION }}

      - name: Install Helm
        uses: azure/setup-helm@v4

      - name: Deploy to prod namespace
        run: |
          helm upgrade --install patient-service ./helm/patient-service \
            -f helm/patient-service/values-prod.yaml \
            --set image.repository=${{ env.ECR_REPO }} \
            --set image.tag=${{ github.sha }} \
            --namespace prod \
            --create-namespace \
            --wait \
            --timeout 5m

      - name: Verify deployment
        run: kubectl rollout status deployment/patient-service -n prod --timeout=3m
```

---

## 5. Setting Up the Manual Approval Gate

The `environment: production` in `deploy-prod` triggers GitHub's **Environment Protection
Rules**. Set it up in your repo:

1. Go to your GitHub repo → **Settings → Environments → New environment**
2. Name it `production`
3. Enable **Required reviewers** and add yourself
4. Save

Now when `deploy-dev` succeeds, the pipeline **pauses** and sends you an email:
*"patient-service is waiting for your review to deploy to production."*
You review the dev deployment, approve, and prod deploys.

> 🧠 **This is the pattern real companies use.** Dev deploys automatically on every
> merge to main. Prod requires human approval. For a startup that might be 1 person
> approving; for a big company it might require two engineers.

---

## 6. Terraform Pipeline

`.github/workflows/terraform.yml` — runs plan on PRs, apply on merge:

```yaml
name: terraform

on:
  push:
    branches: [main]
    paths: ["terraform/**"]
  pull_request:
    paths: ["terraform/**"]

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false   # never cancel Terraform — incomplete apply = broken state

permissions:
  id-token: write
  contents: read
  pull-requests: write        # so the bot can comment the plan on the PR

jobs:
  plan:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        stack: [eks, platform]  # bootstrap is manual-only

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-github-deploy
          aws-region: ap-south-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"

      - name: terraform init
        run: cd terraform/${{ matrix.stack }} && terraform init

      - name: terraform plan
        id: plan
        run: |
          cd terraform/${{ matrix.stack }}
          terraform plan -no-color -out=tfplan 2>&1 | tee plan_output.txt

      - name: Comment plan on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const plan = require('fs').readFileSync('terraform/${{ matrix.stack }}/plan_output.txt', 'utf8');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Terraform plan: \`${{ matrix.stack }}\`\n\`\`\`\n${plan.slice(-65000)}\n\`\`\``
            });

  apply:
    runs-on: ubuntu-latest
    needs: plan
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    strategy:
      matrix:
        stack: [eks, platform]
      max-parallel: 1   # apply stacks sequentially — eks must finish before platform

    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-github-deploy
          aws-region: ap-south-1
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"
      - name: terraform apply
        run: |
          cd terraform/${{ matrix.stack }}
          terraform init
          terraform apply -auto-approve
```

---

## 7. The IAM Role for GitHub Actions

The pipeline authenticates via OIDC — no stored AWS keys in GitHub secrets.
The IAM role is created in `terraform/eks/oidc.tf`:

```hcl
resource "aws_iam_role" "github_deploy" {
  name = "cloudcare-k8s-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Pin to your repo — forks cannot assume this role
          "token.actions.githubusercontent.com:sub" = "repo:your-username/cloudcare-k8s:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "cloudcare-k8s-github-deploy-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:ap-south-1:*:cluster/cloudcare-k8s"
      },
      {
        Effect   = "Allow"
        Action   = ["terraform:*"]   # for the Terraform pipeline
        Resource = "*"
      }
    ]
  })
}
```

---

## 8. GitHub Repository Variables

In your GitHub repo, set these under **Settings → Secrets and variables → Actions**:

| Name | Type | Value |
|---|---|---|
| `AWS_ACCOUNT_ID` | Variable (not secret) | Your 12-digit AWS account ID |

The role ARN is constructed from this variable: no hardcoded account IDs in the YAML.

---

## 9. Comparison: v1 vs v2 CI/CD

| | CloudCare v1 | CloudCare-K8s v2 |
|---|---|---|
| Image tag | `:latest` | Git SHA (`:abc1234`) |
| Tests before build | None | `pytest` on every PR and push |
| How many pipelines | 1 for the whole backend | 1 per service |
| Deploy scope | All or nothing | Service by service |
| Deploy time | ~5 min (instance refresh) | ~30 sec (rolling pod update) |
| Rollback | Re-push old image | `helm rollback <service> 1` |
| Prod approval | Not required | Manual approval gate |

---

## ✅ Checkpoint

You should be able to answer:

- Why do we tag Docker images with the git SHA instead of `:latest`?
- What does `concurrency.cancel-in-progress: true` prevent?
- What happens when `deploy-prod` has `environment: production` set?
- Why don't we store AWS access keys in GitHub Secrets?
- What does `--wait --timeout 3m` do in the `helm upgrade` command?
- How do you roll back a bad prod deployment?

Next: **[07 — IRSA and External Secrets Operator](07-secrets.md)** — make pods
assume their own IAM roles and pull secrets from AWS Secrets Manager automatically.
