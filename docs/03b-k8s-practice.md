# 03b — Kubernetes Practice: Writing Every Manifest

> **Read 03a first.** This doc assumes you understand what Pod, Deployment,
> Service, Namespace, ConfigMap, and Secret are.
>
> **Goal:** write every YAML file for all 6 services, understand every single
> line, apply them to minikube, and verify the system works end to end.

All work runs on **minikube — zero cost.**

---

## 1. What we are building

By the end of this doc, 6 things will be running inside your minikube cluster:

```
namespace: dev
├── postgres          (database — stores patients and appointments)
├── dynamodb-local    (fake AWS DynamoDB — stores audit events)
├── patient-service   (port 8001)
├── appointment-service (port 8002)
├── audit-service     (port 8003)
└── notification-service (port 8004)
```

Every YAML file lives in `k8s/base/`. Create that directory now:

```bash
mkdir -p /home/chalaka/cloud-care-both/cloud-care-k8s/k8s/base
cd /home/chalaka/cloud-care-both/cloud-care-k8s
```

---

## 2. namespaces.yaml — create the virtual floors

**What this file does:** creates the `dev`, `prod`, and `monitoring` namespaces.
Without this, everything goes into the `default` namespace which is messy.

`k8s/base/namespaces.yaml`:
```yaml
apiVersion: v1          # which version of the Kubernetes API to use for this resource
kind: Namespace         # the TYPE of resource we are creating
metadata:
  name: dev             # the name of this namespace
  labels:
    environment: dev    # a label — used later by network policies to identify this namespace
---                     # this --- separates multiple resources in one file
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    environment: prod
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring      # Prometheus, Grafana, Loki will go here (Doc 09)
```

Apply it:
```bash
kubectl apply -f k8s/base/namespaces.yaml

# verify the namespaces were created
kubectl get namespaces
# NAME          STATUS
# default       Active   ← built-in, always exists
# dev           Active   ← we created this
# monitoring    Active   ← we created this
# prod          Active   ← we created this
```

---

## 3. infrastructure.yaml — postgres and DynamoDB Local

**What this file does:** runs postgres and dynamodb-local as pods inside the cluster.
Both are needed before any microservice can start.

First, upload init.sql into the cluster as a ConfigMap so postgres can read it:
```bash
# This takes the init.sql file from your laptop and stores it inside Kubernetes
# as a ConfigMap named "postgres-init" in the dev namespace
kubectl create configmap postgres-init \
  --from-file=init.sql=services/init.sql \
  --namespace dev

# verify it was created
kubectl get configmap postgres-init -n dev
```

`k8s/base/infrastructure.yaml`:
```yaml
# ════════════════════════════════════════
# PART 1: PostgreSQL
# ════════════════════════════════════════

apiVersion: apps/v1       # Deployment resource uses apps/v1 API
kind: Deployment
metadata:
  name: postgres          # name of the Deployment (also used to find it with kubectl)
  namespace: dev          # which namespace to put this in
  labels:
    app: postgres         # label — used by the Service below to find this pod
spec:                     # spec = "what I want Kubernetes to do"
  replicas: 1             # run exactly 1 postgres pod at all times
  selector:
    matchLabels:
      app: postgres       # this Deployment manages pods that have label app=postgres
  template:               # template = what each pod should look like
    metadata:
      labels:
        app: postgres     # every pod created by this Deployment gets this label
    spec:
      containers:
        - name: postgres            # name of the container inside the pod
          image: postgres:16        # Docker image to use (postgres version 16)
          ports:
            - containerPort: 5432   # port postgres listens on INSIDE the pod
          env:
            - name: POSTGRES_DB       # environment variable: which database to create
              value: "cloudcare"
            - name: POSTGRES_USER     # environment variable: admin username
              value: "admin"
            - name: POSTGRES_PASSWORD # environment variable: admin password
              value: "local_password"
          volumeMounts:
            - name: init-sql                            # which volume to mount
              mountPath: /docker-entrypoint-initdb.d    # WHERE inside the container
              # postgres automatically runs any .sql file in this directory on first start
          readinessProbe:           # kubernetes checks this before sending traffic to pod
            exec:
              command: ["pg_isready", "-U", "admin", "-d", "cloudcare"]
              # pg_isready is a postgres tool that exits 0 if postgres is accepting connections
            initialDelaySeconds: 5  # wait 5 seconds after pod starts before first check
            periodSeconds: 5        # then check every 5 seconds
      volumes:
        - name: init-sql            # define a volume named "init-sql"
          configMap:
            name: postgres-init     # fill it with the ConfigMap we created above
            # this makes init.sql available inside the container at the mountPath above
---
apiVersion: v1
kind: Service
metadata:
  name: postgres          # other pods call this service using the name "postgres"
  namespace: dev
spec:
  selector:
    app: postgres         # route traffic to pods that have label app=postgres
  ports:
    - port: 5432          # the port OTHER PODS use to connect (e.g. postgres:5432)
      targetPort: 5432    # the port ON THE POD that actually receives the connection
  type: ClusterIP         # ClusterIP = only reachable inside the cluster, not from outside

---
# ════════════════════════════════════════
# PART 2: DynamoDB Local
# ════════════════════════════════════════

apiVersion: apps/v1
kind: Deployment
metadata:
  name: dynamodb-local
  namespace: dev
  labels:
    app: dynamodb-local
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dynamodb-local
  template:
    metadata:
      labels:
        app: dynamodb-local
    spec:
      containers:
        - name: dynamodb-local
          image: amazon/dynamodb-local:2.3.0  # Amazon's fake DynamoDB for local dev
          command: ["java", "-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]
          # IMPORTANT: in Kubernetes, "command" overrides the image's ENTRYPOINT
          # so we must include the full java command here, not just the arguments.
          # "-inMemory" means data is lost when the pod restarts (fine for dev)
          ports:
            - containerPort: 8000   # DynamoDB Local listens on port 8000
---
apiVersion: v1
kind: Service
metadata:
  name: dynamodb-local    # audit-service calls this using "dynamodb-local:8000"
  namespace: dev
spec:
  selector:
    app: dynamodb-local
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
```

---

## 4. patient-service.yaml

**What this file does:** runs patient-service with its Deployment, Service, and
a Secret that holds the database password.

`k8s/base/patient-service.yaml`:
```yaml
# ════════════════════════════════════════
# PART 1: Deployment
# ════════════════════════════════════════

apiVersion: apps/v1
kind: Deployment
metadata:
  name: patient-service
  namespace: dev
  labels:
    app: patient-service
spec:
  replicas: 1                  # 1 pod — enough for dev
  selector:
    matchLabels:
      app: patient-service     # this Deployment manages pods with label app=patient-service
  template:
    metadata:
      labels:
        app: patient-service   # pods created by this Deployment all get this label
    spec:
      containers:
        - name: patient-service
          image: patient-service:local   # the image we built with: docker build -t patient-service:local
          imagePullPolicy: Never         # NEVER try to pull from internet — use local image only
          # (minikube has its own Docker daemon, images are built there with eval $(minikube docker-env))
          ports:
            - containerPort: 8001        # patient-service FastAPI app listens on 8001
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:            # read this value FROM a Secret (not plain text)
                  name: patient-service-db-secret  # the name of the Secret (defined below)
                  key: DATABASE_URL       # which key inside that Secret to use
            - name: DB_SCHEMA
              value: "patients"          # tells SQLAlchemy to use the "patients" schema
            - name: AUDIT_SERVICE_URL
              value: "http://audit-service:8003"  # DNS name of audit-service inside the cluster
          resources:
            requests:
              memory: "64Mi"   # guaranteed minimum RAM for this pod
              cpu: "50m"       # guaranteed minimum CPU (50 millicores = 5% of one CPU)
            limits:
              memory: "128Mi"  # pod is KILLED if it uses more than this RAM
              cpu: "200m"      # pod is THROTTLED (slowed down) if it uses more than this
          readinessProbe:
            httpGet:
              path: /health    # kubernetes hits this endpoint to check if pod is ready
              port: 8001
            initialDelaySeconds: 5    # wait 5s after container starts before first check
            periodSeconds: 10         # check every 10 seconds
            # pod only gets traffic from the Service AFTER this probe returns 200
          livenessProbe:
            httpGet:
              path: /health    # kubernetes hits this to check if pod is still alive
              port: 8001
            initialDelaySeconds: 15   # longer delay — app needs time to fully start
            periodSeconds: 20         # check every 20 seconds
            # if this returns non-200 or times out → kubernetes RESTARTS the pod

---
# ════════════════════════════════════════
# PART 2: Service
# ════════════════════════════════════════

apiVersion: v1
kind: Service
metadata:
  name: patient-service   # THIS NAME is the DNS hostname other pods use
  namespace: dev          # appointment-service calls: http://patient-service:8001
spec:
  selector:
    app: patient-service  # route to pods that have label app=patient-service
  ports:
    - protocol: TCP
      port: 8001          # port OTHER pods use (the external port of the Service)
      targetPort: 8001    # port ON THE POD that receives the connection
  type: ClusterIP         # internal only — not exposed outside the cluster

---
# ════════════════════════════════════════
# PART 3: Secret
# ════════════════════════════════════════

apiVersion: v1
kind: Secret
metadata:
  name: patient-service-db-secret   # the name referenced in the Deployment above
  namespace: dev
type: Opaque              # Opaque = generic secret (as opposed to docker-registry etc.)
stringData:               # stringData lets you write plain text — Kubernetes auto-encodes to base64
  DATABASE_URL: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
  # patient_svc is the database user created by init.sql
  # postgres is the Service name (DNS resolves to the postgres Service's ClusterIP)
  # cloudcare is the database name
  # 5432 is postgres's port
```

---

## 5. appointment-service.yaml

**Key difference from patient-service:** appointment-service needs 3 extra environment
variables — the URLs to reach patient-service, audit-service, and notification-service.

`k8s/base/appointment-service.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appointment-service
  namespace: dev
  labels:
    app: appointment-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: appointment-service
  template:
    metadata:
      labels:
        app: appointment-service
    spec:
      containers:
        - name: appointment-service
          image: appointment-service:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8002
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: appointment-service-db-secret
                  key: DATABASE_URL
            - name: DB_SCHEMA
              value: "appointments"
            - name: PATIENT_SERVICE_URL
              value: "http://patient-service:8001"
              # used for SYNC call: verify patient exists before creating appointment
            - name: AUDIT_SERVICE_URL
              value: "http://audit-service:8003"
              # used for ASYNC call: log audit event after appointment is created
            - name: NOTIFICATION_SERVICE_URL
              value: "http://notification-service:8004"
              # used for ASYNC call: send confirmation email after appointment is created
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: appointment-service
  namespace: dev
spec:
  selector:
    app: appointment-service
  ports:
    - port: 8002
      targetPort: 8002
  type: ClusterIP
---
apiVersion: v1
kind: Secret
metadata:
  name: appointment-service-db-secret
  namespace: dev
type: Opaque
stringData:
  DATABASE_URL: "postgresql://appt_svc:appt_pass@postgres:5432/cloudcare"
  # appt_svc is the appointment database user created by init.sql
```

---

## 6. audit-service.yaml

**Key difference:** audit-service uses DynamoDB, not postgres. No DATABASE_URL.
Instead it has DynamoDB-specific env vars. In dev these point to dynamodb-local
running in the cluster. In prod (Doc 07), they are removed and IRSA is used instead.

`k8s/base/audit-service.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audit-service
  namespace: dev
  labels:
    app: audit-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: audit-service
  template:
    metadata:
      labels:
        app: audit-service
    spec:
      containers:
        - name: audit-service
          image: audit-service:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8003
          env:
            - name: DYNAMODB_TABLE
              value: "audit_events"          # the DynamoDB table name to store events in
            - name: AWS_DEFAULT_REGION
              value: "ap-south-1"
            - name: DYNAMODB_ENDPOINT_URL
              value: "http://dynamodb-local:8000"
              # this tells boto3 (AWS Python SDK) to use our local fake DynamoDB
              # instead of real AWS DynamoDB. Remove this in prod.
            - name: AWS_ACCESS_KEY_ID
              value: "local"
              # DynamoDB Local requires SOME credentials but doesn't validate them.
              # So we use fake values. In prod, IRSA provides real credentials
              # automatically — no keys needed in the YAML.
            - name: AWS_SECRET_ACCESS_KEY
              value: "local"
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: audit-service     # patient-service and appointment-service call this name
  namespace: dev
spec:
  selector:
    app: audit-service
  ports:
    - port: 8003
      targetPort: 8003
  type: ClusterIP         # internal only — never exposed to the internet
```

---

## 7. notification-service.yaml

**Key difference:** no database at all. Only needs `LOCAL_DEV=true` in dev to
log emails to the console instead of calling real AWS SES.

`k8s/base/notification-service.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notification-service
  namespace: dev
  labels:
    app: notification-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notification-service
  template:
    metadata:
      labels:
        app: notification-service
    spec:
      containers:
        - name: notification-service
          image: notification-service:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8004
          env:
            - name: LOCAL_DEV
              value: "true"
              # when LOCAL_DEV=true, the service logs emails to console instead of
              # calling real AWS SES. This avoids needing SES configured in dev.
            - name: SES_FROM_ADDRESS
              value: "noreply@cloudcare.local"  # the "From:" address in emails
            - name: AWS_DEFAULT_REGION
              value: "ap-south-1"
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8004
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8004
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: notification-service
  namespace: dev
spec:
  selector:
    app: notification-service
  ports:
    - port: 8004
      targetPort: 8004
  type: ClusterIP           # internal only — never publicly reachable
```

---

## 8. Apply everything — correct order matters

**Why order matters:**
- postgres must exist before patient-service or appointment-service start
- dynamodb-local must exist before audit-service starts
- namespaces must exist before anything else

```bash
# STEP 1: create namespaces first — everything else goes into these
kubectl apply -f k8s/base/namespaces.yaml

# STEP 2: upload init.sql into the cluster as a ConfigMap
kubectl create configmap postgres-init \
  --from-file=init.sql=services/init.sql \
  --namespace dev

# STEP 3: start infrastructure (postgres + dynamodb-local)
kubectl apply -f k8s/base/infrastructure.yaml

# STEP 4: wait for postgres to finish running init.sql before starting services
kubectl rollout status deployment/postgres -n dev
# output: deployment "postgres" successfully rolled out

# STEP 5: start all four microservices
kubectl apply -f k8s/base/patient-service.yaml
kubectl apply -f k8s/base/appointment-service.yaml
kubectl apply -f k8s/base/audit-service.yaml
kubectl apply -f k8s/base/notification-service.yaml

# STEP 6: watch everything start up
kubectl get pods -n dev -w
# -w means "watch" — keeps updating in real time
# wait until all show 1/1 Running
```

**What you should see when everything is healthy:**
```
NAME                                    READY   STATUS    RESTARTS   AGE
appointment-service-xxx                 1/1     Running   0          30s
audit-service-xxx                       1/1     Running   0          30s
dynamodb-local-xxx                      1/1     Running   0          60s
notification-service-xxx                1/1     Running   0          30s
patient-service-xxx                     1/1     Running   0          30s
postgres-xxx                            1/1     Running   0          90s
```

`1/1` means: 1 container running out of 1 expected. This is healthy.

---

## 9. Accessing the services (port-forwarding)

The services are inside the cluster. Your laptop is outside. Port-forwarding creates
a temporary tunnel so you can reach them with curl or your browser.

```bash
# Forward all 4 service ports to your laptop
kubectl port-forward svc/patient-service      8001:8001 -n dev &
kubectl port-forward svc/appointment-service  8002:8002 -n dev &
kubectl port-forward svc/audit-service        8003:8003 -n dev &
kubectl port-forward svc/notification-service 8004:8004 -n dev &

# the & means run in background so your terminal is free
# stop all port-forwards when done: pkill -f "kubectl port-forward"
```

---

## 10. Test that everything works

```bash
# 1. Check health of all services
curl http://localhost:8001/health   # {"status":"ok","service":"patient-service"}
curl http://localhost:8002/health   # {"status":"ok","service":"appointment-service"}
curl http://localhost:8003/health   # {"status":"ok","service":"audit-service"}
curl http://localhost:8004/health   # {"status":"ok","service":"notification-service","mode":"local_dev"}

# 2. Create a patient
curl -X POST http://localhost:8001/patients \
  -H "Content-Type: application/json" \
  -d '{"full_name": "Nimal Silva", "date_of_birth": "1985-03-15", "phone": "077-123-4567"}'
# response: {"id": 1, "full_name": "Nimal Silva", ...}

# 3. Create an appointment (uses patient_id from step 2)
curl -X POST http://localhost:8002/appointments \
  -H "Content-Type: application/json" \
  -d '{"patient_id": 1, "scheduled_for": "2026-07-15T09:00:00", "reason": "Annual checkup"}'
# response: {"id": 1, "patient_id": 1, "status": "scheduled", ...}

# 4. Verify audit-service received the event
curl http://localhost:8003/audit
# should show audit events for patient created and appointment created

# 5. Verify notification-service logged the email
kubectl logs deployment/notification-service -n dev | grep -A3 "Email"
```

---

## 11. Debugging — what to do when pods don't start

```bash
# See all pods and their status
kubectl get pods -n dev

# Pod is in "CrashLoopBackOff" or "Error" — get details:
kubectl describe pod <pod-name> -n dev
# look at: Events section at the bottom — shows exactly what went wrong

# See what the pod printed to the console before crashing:
kubectl logs <pod-name> -n dev

# See logs from the PREVIOUS crashed instance (if current pod is restarting):
kubectl logs <pod-name> -n dev --previous

# Open a shell inside a running pod to investigate:
kubectl exec -it <pod-name> -n dev -- /bin/sh

# See all resources in dev namespace at once:
kubectl get all -n dev
```

**Common problems and fixes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Docker image not found | Run `eval $(minikube docker-env)` then rebuild image |
| `CrashLoopBackOff` | App crashes on startup | Check `kubectl logs <pod> --previous` |
| `postgres` pod not ready | init.sql failed | Check `kubectl logs deployment/postgres -n dev` |
| Services can't talk to each other | Wrong service name in env var | Check env var matches Service name exactly |

---

## ✅ Checkpoint — you are done with Doc 03 when:

- [ ] All 6 pods show `1/1 Running` in `kubectl get pods -n dev`
- [ ] All 4 health checks return 200 via curl
- [ ] Creating a patient returns an id
- [ ] Creating an appointment (using that patient id) returns an id
- [ ] `kubectl logs deployment/notification-service -n dev` shows a logged email
- [ ] `kubectl logs deployment/audit-service -n dev` shows "audit event stored"

Next: **[04a — Helm Concepts](04a-helm-concepts.md)** — understand why Helm
exists and what it does before writing any chart.
