# 00 — The Roadmap

> **Goal of this doc:** give you the whole map before we start the journey, so you always
> know *where you are*, *why this step exists*, and *what's next*.

If you only read one paragraph: we are going to take the hospital management app from
CloudCare v1 (EC2/ASG/Terraform) and re-platform it onto **Kubernetes (EKS)** — the way
modern engineering teams actually run production workloads. By the end you'll be able to
decompose a monolith into microservices, write Kubernetes manifests and Helm charts,
provision an EKS cluster with Terraform, run independent CI/CD pipelines per service,
and operate a full three-pillar observability stack. That is exactly what a senior
SRE/DevOps interview wants to see.

---

## 1. What You Already Know (and Why It Matters Here)

If you completed CloudCare v1, you already understand:

- **Terraform** — remote state, modules, `terraform apply`, cross-stack reads
- **VPC networking** — subnets, security groups, NACLs, route tables
- **IAM** — least privilege, OIDC federation, instance profiles
- **Docker** — building images, pushing to ECR
- **GitHub Actions** — OIDC auth, build/push/deploy workflows
- **RDS, DynamoDB, Secrets Manager, SES** — the AWS services the app uses

CloudCare-K8s **builds directly on all of this**. The VPC layout is the same. The IAM
principles are the same. The application code (FastAPI, React) is the same. What changes
is the *compute layer*: instead of an EC2 Auto Scaling Group running one monolith, we
run **four independent microservices as pods on an EKS cluster**.

> 🧠 **Why Kubernetes?** On EC2/ASG, scaling means waiting ~5 minutes for a new instance
> to boot. On Kubernetes, scaling means adding a pod in ~30 seconds. Deployments are
> rolling and zero-downtime. Rollback is one command. Every service scales independently.
> And the tooling (Helm, Prometheus, Grafana) is the industry standard — you'll see it
> everywhere once you're in the field.

---

## 2. How This Project Is Structured

Same rhythm as CloudCare v1 — every phase has numbered docs:

1. **Concept** — what the technology is, in plain language, and why it exists.
2. **Design** — what we're building and the cost implications.
3. **Code** — manifests, Terraform, and Helm charts, explained line by line.
4. **Apply & verify** — run it, look at it, confirm it works.
5. **Destroy** — tear down the expensive bits; keep developing locally for free.

---

## 3. The Phases at a Glance

| Phase | Doc | Topic | Key tools | Free-tier risk |
|------:|-----|-------|-----------|----------------|
| **0** | [00](00-roadmap.md), [01](01-local-setup.md) | Foundations — local setup, Docker Compose, minikube | Docker, minikube, kubectl | ✅ Completely free |
| **1** | [02](02-microservices-split.md) | Microservices split — 4 independent services | FastAPI, Docker Compose | ✅ Free (local only) |
| **2** | [03](03-k8s-manifests.md) | Kubernetes manifests — Deployment, Service, Ingress | kubectl, minikube | ✅ Free (local only) |
| **3** | [04](04-helm-charts.md) | Helm charts — packaging, values, dev/prod overlays | Helm 3 | ✅ Free (local only) |
| **4** | [05](05-eks-terraform.md) | EKS cluster with Terraform | Terraform, EKS | ⚠️ EKS ~$2.40/day |
| **5** | [06](06-cicd.md) | CI/CD — per-service GitHub Actions pipelines | GitHub Actions, ECR | ✅ Free |
| **6** | [07](07-secrets.md) | IRSA + External Secrets Operator | Secrets Manager, ESO | ✅ Free within tier |
| **7** | [08](08-hpa.md) | HPA — horizontal pod autoscaling | kubectl, Metrics Server | ✅ Free |
| **8** | [09](09-observability.md) | Prometheus + Grafana + Loki | Helm, Prometheus stack | ✅ Free |
| **9** | [10](10-multi-env.md) | Multi-environment (dev/prod namespaces) | Kustomize, Helm | ✅ Free |

---

## 4. What "Done" Looks Like

By the end of this project you will be able to:

- Explain the difference between a monolith and microservices, and the trade-offs of each.
- Draw the Kubernetes architecture from memory: nodes, pods, services, ingress, namespaces.
- Write a Kubernetes `Deployment` and `Service` from scratch.
- Package any microservice into a Helm chart with dev and prod value overrides.
- Provision a production-grade EKS cluster with Terraform (VPC, OIDC, IRSA, node groups).
- Set up an independent CI/CD pipeline per service that tests, builds, and deploys automatically.
- Configure External Secrets Operator to sync AWS Secrets Manager credentials into pod envs.
- Set up HPA to automatically scale pods under load.
- Stand up Prometheus + Grafana + Loki and explain what each metric means.
- Talk fluently about the difference between v1 and v2 and *why* you'd choose Kubernetes.

---

## 5. The Learning Schedule (Suggested)

This builds on CloudCare v1, so assumes you already understand Terraform, IAM, and Docker.
Estimated time: **6–8 hours/week** for two months.

### Month 1 — Local → Kubernetes Fundamentals

- **Week 1:** Doc 01. Get all tools installed. Run all 4 services with Docker Compose.
  Understand why Docker Compose is not Kubernetes.
- **Week 2:** Doc 02. Understand the microservices split. Write the FastAPI code for all
  four services. Run them locally. Understand schema-per-service.
- **Week 3:** Doc 03. Learn Kubernetes concepts. Write Deployments and Services by hand.
  Apply them to minikube. Use `kubectl` daily until it's muscle memory.
- **Week 4:** Doc 04. Package the services into Helm charts. Write `values.yaml`,
  `values-dev.yaml`, `values-prod.yaml`. Deploy via `helm upgrade --install`.

### Month 2 — AWS → CI/CD → Observability

- **Week 5:** Doc 05. Provision the EKS cluster with Terraform. Run `kubectl get nodes`.
  Understand the 3-stack model. **Destroy EKS after each session.**
- **Week 6:** Doc 06. Write GitHub Actions pipelines per service. test → build → push → deploy.
  Manual approval gate for prod.
- **Week 7:** Doc 07. Set up IRSA and External Secrets Operator. Secrets flow from
  Secrets Manager into pod env vars — never touch Git.
- **Week 8:** Doc 08 + 09. Add HPA. Deploy Prometheus + Grafana + Loki. Build dashboards.
  Set up alerting rules. This is the phase interviewers love.
- **Buffer:** Doc 10. Multi-environment dev/prod namespaces with Kustomize.
  Practice `terraform destroy` + full re-deploy until it's boring.

---

## 6. Cost Discipline (Read This Every Time You Deploy EKS)

The **EKS control plane costs ~$0.10/hour (~$2.40/day)** whether you're using it or not.
There is no free tier.

**Three habits that will protect you:**

1. After any EKS lab: `cd terraform/eks && terraform destroy`
2. Do all manifest and Helm work on **minikube** first — completely free.
3. Check **Billing → Free Tier** in the AWS Console once a week.

The total estimated cost for this project when the cluster is running is ~$90/month
(EKS + ALB). This is within the AWS $150 free credit. But if you leave EKS running
accidentally for a week, that's ~$17 wasted. Destroy it.

> 🧠 **Cattle, not pets.** Your Kubernetes manifests and Helm charts are the source of
> truth — not the running cluster. You should be able to `terraform destroy` everything
> and `terraform apply` it back within 20 minutes. That's the skill you're building.

---

## 7. A Note on minikube vs EKS

For phases 0–4 (through Helm), you **don't need AWS at all**. Everything runs on
minikube on your laptop, for free. This is intentional:

- Kubernetes concepts don't change between minikube and EKS.
- Writing and testing manifests locally is 10× faster than deploying to a cloud cluster.
- You save ~$2.40/day until you're ready to test cloud-specific features.

Only in Phase 4 (Doc 05) do we actually spin up EKS. Until then, stay on minikube.

---

## ✅ Checkpoint

You're ready to move on when you can answer:

- What are the 10 phases of this project?
- Why should you do phases 0–3 on minikube before touching EKS?
- What does EKS cost per hour? Per day?
- What's the key difference between CloudCare v1 and v2 in one sentence?

Next: **[01 — Local Setup](01-local-setup.md)** — install all tools, run the 4 services with
Docker Compose, and get your first pod running on minikube.
