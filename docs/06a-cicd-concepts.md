# 06a — CI/CD: Concepts and Mental Model

> **Goal:** understand what CI/CD is, how GitHub Actions works, and how the
> build → push → deploy pipeline connects to everything we built in docs 03–05.
> Read this fully before going to 06b.

---

## 1. The problem without CI/CD

Right now, to deploy a code change you do this manually:

```
1. Edit code
2. docker build -t ...ecr.../patient-service:latest .
3. docker push ...ecr.../patient-service:latest
4. helm upgrade --install patient-service ./helm/patient-service \
     -f values-prod.yaml --set image.tag=latest
5. kubectl get pods -n prod   (watch and hope)
```

That is 4 manual steps. For 4 microservices that is 16 steps.
Do this 10 times a day across a team → mistakes, forgotten steps, inconsistent deploys.

**CI/CD automates all of this.** You push code → a robot does the rest.

```
You:   git push origin main
Robot: ✓ build patient-service image
       ✓ push to ECR with tag abc123
       ✓ helm upgrade patient-service --set image.tag=abc123
       ✓ verify pods running
       Done in 3 minutes.
```

---

## 2. CI vs CD — what each word means

```
CI = Continuous Integration
     Every code push automatically:
     ├── builds the code (compiles, creates Docker image)
     └── runs tests (so bugs are caught before deploy)

CD = Continuous Delivery (or Deployment)
     Every successful CI run automatically:
     └── deploys to the target environment (EKS cluster)
```

In this project:
- **CI**: build Docker image, push to ECR
- **CD**: `helm upgrade` to deploy the new image to EKS

---

## 3. GitHub Actions — the 4 words you must know

### Workflow
A YAML file in `.github/workflows/`. Defines what to do and when.

```
.github/workflows/deploy-patient.yml    ← one workflow per service
```

### Trigger
What causes the workflow to run.

```yaml
on:
  push:
    branches: [main]
    paths: ["services/patient-service/**"]   # only when patient-service code changes
```

Without `paths:`, every push to main — even changing a README — would rebuild all 4 services.
With `paths:`, GitHub only runs this workflow when patient-service files change.

### Job
A unit of work that runs on a virtual machine (called a "runner").
Jobs run in parallel by default. Use `needs:` to chain them sequentially.

```
job: build     → build and push Docker image to ECR
job: deploy    → helm upgrade (needs: build to finish first)
```

### Step
One action inside a job. Steps run sequentially within a job.

```
step 1: checkout code
step 2: configure AWS credentials
step 3: docker build
step 4: docker push
```

---

## 4. How it all connects to what you built

```
oidc.tf created:
  └── aws_iam_openid_connect_provider.github
  └── aws_iam_role.github_deploy   (with ECR push + EKS describe permissions)
         ↑
         GitHub Actions assumes this role using a JWT token
         No stored AWS keys anywhere — the same OIDC pattern as IRSA for pods

ecr.tf created:
  └── cloudcare-k8s-patient-service (ECR repo)
         ↑
         CI pushes the built image here

eks.tf + helm charts created:
  └── EKS cluster + Helm release
         ↑
         CD runs helm upgrade to update the running pods
```

The CI/CD pipeline is not a new concept — it's the automation layer on top of
the manual steps you already know how to do.

---

## 5. OIDC keyless auth — no stored AWS keys in GitHub

This is the same OIDC idea from doc 05a, but for GitHub instead of pods.

**Without OIDC (old, bad way):**
```
GitHub Secrets:
  AWS_ACCESS_KEY_ID:     AKIA...
  AWS_SECRET_ACCESS_KEY: abc123...

Problem: these are long-lived credentials. If GitHub is breached, your AWS
account is compromised. Keys don't auto-expire. Hard to rotate.
```

**With OIDC (our way):**
```
1. GitHub generates a JWT for this specific workflow run:
   { "sub": "repo:chala2001/cloud-care-k8s:ref:refs/heads/main",
     "aud": "sts.amazonaws.com" }

2. Workflow calls AWS STS:
   AssumeRoleWithWebIdentity(role=github_deploy, token=<JWT>)

3. AWS checks: does this JWT match the OIDC provider we registered?
   Does the "sub" match "repo:chala2001/cloud-care-k8s:*"?
   → Yes → issue temporary credentials (valid 15 minutes)

4. Workflow uses temporary credentials to push to ECR + describe EKS
   Credentials expire automatically — nothing to rotate or leak
```

GitHub needs no stored AWS credentials at all. The trust is encoded in
the IAM role's condition (`token.actions.githubusercontent.com:sub`).

---

## 6. The build pipeline — what happens per push

```
Push to main (services/patient-service/app/main.py changed)
│
├── Trigger: push to main + paths match services/patient-service/**
│
├── Job: build
│   ├── checkout: git clone the repo onto the runner VM
│   ├── auth: exchange GitHub JWT for AWS temporary credentials
│   ├── ecr-login: docker login to ECR using those credentials
│   ├── build: docker build -t <ecr-url>/patient-service:<git-sha> .
│   └── push: docker push <ecr-url>/patient-service:<git-sha>
│          tag = git SHA (e.g. "a3f8b2c") — never "latest" in prod
│          why: "latest" is mutable — you can't roll back to it reliably
│               git SHA is immutable — always points to the exact code
│
└── Job: deploy (needs: build)
    ├── auth: same OIDC exchange
    ├── kubeconfig: aws eks update-kubeconfig --name cloudcare-k8s
    └── helm upgrade patient-service ./helm/patient-service \
            -f values-prod.yaml \
            --set image.tag=<git-sha>
        → Kubernetes sees new image tag → rolling update → old pods replaced
```

---

## 7. Why git SHA as the image tag

```
Bad:  image: patient-service:latest
      ↑ "latest" changes every push. helm rollback to revision 1 still uses
        whatever "latest" points to NOW — which is the broken version.
        Rollback doesn't actually roll back the image.

Good: image: patient-service:a3f8b2c
      ↑ immutable. helm rollback to revision 1 = exactly the image from that commit.
        True rollback in 30 seconds.
```

In the workflow: `IMAGE_TAG: ${{ github.sha }}` — GitHub provides the full 40-char SHA.
We use the first 7 chars for readability: `${GITHUB_SHA::7}`.

---

## 8. Two deploy targets — dev and prod

Every service workflow handles both branches in one file:

```
push to dev branch  → deploy-dev job runs  → EKS dev namespace  → values-dev.yaml
push to main branch → deploy-prod job runs → EKS prod namespace → values-prod.yaml
```

The `if:` condition on each job controls which one runs:
```yaml
deploy-dev:
  if: github.ref == 'refs/heads/dev'    # only on dev branch

deploy-prod:
  if: github.ref == 'refs/heads/main'   # only on main branch
```

Both jobs share the same build job — the image is built once and deployed to
whichever environment matches the branch. Dev and prod use the same image,
different Helm values.

---

## 9. Terraform workflow — infrastructure changes

Pushing service code is not the only thing that triggers CI. Changes to
`terraform/` also need automation:

```
PR with terraform/ changes   → terraform plan  (preview, post as PR comment)
Merge to main                → terraform apply (actually change AWS infrastructure)
```

Why plan on PR and apply on merge?
- You see exactly what AWS resources will change before the code lands
- Prevents surprise: "I only changed a tag and somehow deleted the RDS instance"
- Two jobs: `eks` first, then `platform` (platform reads eks outputs — must apply in order)

---

## 10. One workflow per service — why not one for all?

```
Option A: one big workflow, builds all 4 services on every push
  → change 1 line in patient-service → rebuild all 4 → wastes 12 minutes

Option B: one workflow per service, triggered by path filter
  → change 1 line in patient-service → only patient-service rebuilds → 3 minutes
  → faster feedback, less ECR storage consumed, clearer logs
```

We use Option B: 4 workflow files, each with a `paths:` filter.

---

## 9. The full picture

```
Developer laptop:
  git push origin main
        │
        ▼
GitHub:
  detects push to main
  checks which workflow paths match the changed files
  queues matching workflows
        │
        ▼
GitHub Runner (Ubuntu VM, free for public repos):
  job: build
    - checks out code
    - gets AWS creds via OIDC (15-min temp credentials)
    - docker build → push to ECR with git SHA tag
  job: deploy
    - gets AWS creds via OIDC again
    - kubectl configured to talk to EKS
    - helm upgrade → rolling update in EKS
        │
        ▼
EKS:
  new pods start with new image
  old pods terminate after new pods pass readinessProbe
  zero downtime (the readinessProbe you wrote in 03b)
```

---

**You understand the CI/CD mental model. Go to [06b — CI/CD Practice](06b-cicd-practice.md)
to read every line of every workflow file and set up GitHub Actions.**
