#  Brain Tasks App — Production DevOps Pipeline on AWS

 **End-to-end CI/CD pipeline**: React app → Docker → Amazon ECR → Kubernetes (EKS) → automated via AWS CodePipeline + CodeBuild → monitored with CloudWatch.

 **LoadBalancer ARN:** http://a103d6d49925745cf9cb64f395a10155-2117866487.us-east-1.elb.amazonaws.com:3000/

arn:aws:codebuild:us-east-1:193044711070:build/brain-tasks-build:f0a5bdd0-1aa8-4a5e-a945-b4b9fbe18bef
---

##  What This Project Demonstrates

This project replicates a **production-grade DevOps workflow** as used in real engineering teams. It is not a tutorial reproduction — every component is wired together to function as a complete delivery system.

| Concern | Implementation |
|---|---|
| Containerization | Single-stage `nginx:alpine` Dockerfile — repo ships pre-compiled `dist/`, no build step required |
| Image Registry | Amazon ECR (private, tagged by Git commit SHA) |
| Orchestration | AWS EKS (Kubernetes) with health probes + resource limits |
| CI/CD | AWS CodePipeline → CodeBuild → `kubectl` deploy |
| Monitoring | CloudWatch Logs for build, deploy, and runtime logs |
| Version Control | GitHub (pipeline trigger on `main` branch push) |

---

##  Architecture

```
Developer
    │
    │  git push → main
    ▼
┌─────────────────────────────────────────────────────────┐
│                    GitHub Repository                     │
│              (Source of Truth + Pipeline Trigger)        │
└───────────────────────┬─────────────────────────────────┘
                        │ Webhook
                        ▼
┌─────────────────────────────────────────────────────────┐
│                  AWS CodePipeline                        │
│                                                          │
│   ┌──────────┐    ┌──────────────┐    ┌──────────────┐  │
│   │  SOURCE  │───▶│    BUILD     │───▶│    DEPLOY    │  │
│   │ (GitHub) │    │ (CodeBuild)  │    │  (EKS/kubectl│  │
│   └──────────┘    └──────┬───────┘    └──────────────┘  │
└──────────────────────────┼──────────────────────────────┘
                           │ Push image
                           ▼
              ┌────────────────────────┐
              │      Amazon ECR        │
              │  (Docker Image Store)  │
              │  Tagged: $COMMIT_SHA   │
              └────────────┬───────────┘
                           │ Pull image
                           ▼
┌─────────────────────────────────────────────────────────┐
│                   AWS EKS Cluster                        │
│                                                          │
│   ┌─────────────────────────────────────────────────┐   │
│   │               Kubernetes Deployment              │   │
│   │   Pod(1)  Pod(2)  Pod(3)  ← replicas: 3         │   │
│   │   [React App Container — port 3000]              │   │
│   │   livenessProbe  ✓    readinessProbe  ✓          │   │
│   │   CPU: 250m/500m      Memory: 256Mi/512Mi        │   │
│   └─────────────────────┬───────────────────────────┘   │
│                         │                                │
│   ┌─────────────────────▼───────────────────────────┐   │
│   │         Kubernetes Service (LoadBalancer)        │   │
│   │         External traffic → port 3000             │   │
│   └─────────────────────────────────────────────────┘   │
└───────────────────────────────┬─────────────────────────┘
                                │
                    ┌───────────▼──────────┐
                    │   AWS LoadBalancer   │
                    │  (Public endpoint)   │
                    └──────────────────────┘

        All stages emit logs to → AWS CloudWatch
```

---

##  Repository Structure

```
Brain-Tasks-App/
│
├── src/                        # React application source (unchanged from upstream)
├── public/
│
├── Dockerfile                  # Multi-stage build: node:alpine build → nginx serve
├── buildspec.yml               # CodeBuild pipeline instructions
│
├── k8s/
│   ├── deployment.yaml         # EKS deployment with probes + resource limits
│   └── service.yaml            # LoadBalancer service exposing port 3000
│
├── screenshots/                # Pipeline, cluster, and app screenshots
│   ├── codepipeline-run.png
│   ├── codebuild-logs.png
│   ├── eks-pods.png
│   └── app-running.png
│
└── README.md
```

---

##  Phase 1 — Dockerize the Application

The upstream repository ships **pre-compiled static output** in `dist/` — there is no `package.json` or source code. The build step has already been done upstream; this repo is deployment-focused by design.

The Dockerfile uses `nginx:1.25-alpine` as a single stage — copying `dist/` directly into the nginx web root. Final image size is approximately 25MB.

A custom `nginx.conf` is included alongside the Dockerfile. This is required for React Router: without the `try_files` fallback directive, any client-side route (e.g. `/tasks`) returns a 404 because nginx looks for a real file at that path. The config catches all unmatched paths and returns `index.html`, letting React handle routing client-side.

Additional nginx config details:
- `index.html` served with `no-cache` headers — ensures users always get the latest deploy
- Hashed static assets (JS/CSS) served with `immutable` 1-year cache — safe because filenames change on each build
- Gzip compression enabled for `text`, `js`, `css`, `svg`

---

##  Phase 2 — Amazon ECR

Images are pushed to a private ECR repository and tagged with the Git commit SHA for traceability.

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS \
    --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Create ECR repository (one-time)
aws ecr create-repository --repository-name brain-tasks-app --region us-east-1

# Tag and push
docker tag brain-tasks-app:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
```

---

##  Phase 3 — Kubernetes on AWS EKS

### Cluster Setup

```bash
# Create EKS cluster using eksctl (recommended)
eksctl create cluster \
  --name brain-tasks-cluster \
  --region us-east-1 \
  --nodegroup-name standard-nodes \
  --node-type t3.medium \
  --nodes 2

# Verify cluster is running
kubectl get nodes
```

### Kubernetes Manifests

#### `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: brain-tasks-app
  labels:
    app: brain-tasks-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: brain-tasks-app
  template:
    metadata:
      labels:
        app: brain-tasks-app
    spec:
      containers:
        - name: brain-tasks-app
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
```

#### `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: brain-tasks-service
spec:
  selector:
    app: brain-tasks-app
  type: LoadBalancer
  ports:
    - protocol: TCP
      port: 3000
      targetPort: 80
```

```bash
# Deploy to EKS
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Check pods and get LoadBalancer URL
kubectl get pods
kubectl get service brain-tasks-service
```

---

##  Phase 4 — CI/CD Pipeline

### `buildspec.yml`


### CodePipeline Structure

| Stage | Provider | Action |
|---|---|---|
| Source | GitHub (v2) | Trigger on push to `main` |
| Build | AWS CodeBuild | Run `buildspec.yml` |
| Deploy | CodeBuild (post_build) | `kubectl set image` + rollout |

> **IAM Note:** The CodeBuild service role requires:
> - `AmazonEC2ContainerRegistryPowerUser` — push to ECR
> - `eks:DescribeCluster` + `eks:UpdateClusterConfig` — access EKS
> - The EKS `aws-auth` ConfigMap must include the CodeBuild role ARN

---

##  Phase 5 — Monitoring with CloudWatch

CloudWatch is used to capture logs at every stage of the pipeline.

| Log Source | Log Group |
|---|---|
| CodeBuild build logs | `/aws/codebuild/brain-tasks-build` |
| EKS control plane | `/aws/eks/brain-tasks-cluster/cluster` |
| Application container logs | Forwarded via Fluent Bit DaemonSet → CloudWatch |

```bash
# Tail live CodeBuild logs from CLI
aws logs tail /aws/codebuild/brain-tasks-build --follow

# Check pod logs directly
kubectl logs -l app=brain-tasks-app --tail=50
```

---

##  Live Application

After deployment, retrieve the LoadBalancer DNS:

```bash
kubectl get service brain-tasks-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Application accessible at: `http://<LOAD_BALANCER_DNS>:3000`

**LoadBalancer ARN:** http://a103d6d49925745cf9cb64f395a10155-2117866487.us-east-1.elb.amazonaws.com:3000/

---

##  IAM Requirements Summary

| Role | Permissions Needed |
|---|---|
| CodeBuild Service Role | ECR push, EKS describe + auth |
| EKS Node Role | ECR pull, CloudWatch logs |
| EKS `aws-auth` ConfigMap | CodeBuild role mapped to `system:masters` |

---

## Screenshots

| Screenshot | Description |
|---|---|
| `codepipeline-run.png` | Successful 3-stage pipeline execution |
| `cloudwatch-logs.png` | Build + push + deploy phases in CodeBuild |
| `eks-pods.png` | 3 running pods across EKS nodes |
| `app-running.png` | React app live via LoadBalancer URL |

---

## Key Technical Decisions

**Why nginx:alpine instead of a Node-based image?**
The upstream repo ships pre-compiled `dist/` output — no Node.js runtime is needed to serve static files. `nginx:alpine` is purpose-built for this: it handles HTTP, compression, caching headers, and high concurrency with a ~25MB footprint. Running a Node server to serve static files would add unnecessary weight and attack surface.

**Why a custom nginx.conf?**
The default nginx config has no `try_files` fallback. React Router handles routing client-side, meaning paths like `/tasks` are not real files on disk. Without the fallback, nginx returns 404 for any route except `/`. The custom config catches all unmatched paths and returns `index.html`, letting React take over.

**Why tag images with commit SHA?**
Using `:latest` makes rollback impossible. Tagging with `$COMMIT_HASH` means every deployment is traceable to a specific commit and rollback is a single `kubectl set image` command.

**Why liveness and readiness probes?**
Without probes, Kubernetes cannot distinguish a crashed container from a running one. Readiness probes prevent traffic from reaching pods that haven't finished starting up.

**Why resource requests and limits?**
Without limits, a misbehaving pod can consume all node resources and cause noisy-neighbour failures across the cluster.
**Why CodeStar Connection is recommended?"

A CodeStar Connection is the current AWS-recommended approach for GitHub integration, avoiding personal access token---

## Possible Extensions

| Enhancement | Tool |
|---|---|
| Infrastructure as Code | Terraform (EKS cluster, ECR, IAM) |
| GitOps delivery | ArgoCD |
| Helm-based deployment | Helm charts replacing raw YAML |
| Blue/Green or Canary deployments | AWS CodeDeploy or Flagger |
| Metrics + alerting | Prometheus + Grafana on EKS |
| Secrets management | AWS Secrets Manager + External Secrets Operator |

---

##  Author

**Preethi Chandrasekan/ DevOps / Cloud Engineer**
Specialization: AWS · Kubernetes · CI/CD · Container Infrastructure

---

