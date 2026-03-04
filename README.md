#  Brain Tasks App — Production DevOps Pipeline on AWS

> **End-to-end CI/CD pipeline**: React app → Docker → Amazon ECR → Kubernetes (EKS) → automated via AWS CodePipeline + CodeBuild → monitored with CloudWatch.

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
│   │   CPU: 250m/500m      Memory: 128Mi/256Mi        │   │
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
├── dist/                       # Pre-compiled React app (from upstream)
│
├── Dockerfile                  # nginx:alpine serving dist/ — no build stage needed
├── nginx.conf                  # SPA routing fallback, gzip, cache headers
├── .dockerignore               # Excludes CI/CD configs from image build context
├── buildspec.yml               # CodeBuild pipeline instructions
│
├── k8s/
│   ├── deployment.yaml         # EKS deployment with probes + resource limits
│   └── service.yaml            # LoadBalancer service exposing port 3000
│
├── Screenshots/
│   ├── codepipeline.png        # Successful pipeline execution
│   ├── eks-pods.png            # 3 running pods across EKS nodes
│   └── app-running.png         # React app live via LoadBalancer URL
│
└── README.md
```

---

##  Phase 1 — Dockerize the Application

The upstream repository ships **pre-compiled static output** in `dist/` — there is no `package.json` or source code. The build step has already been done upstream; this repo is deployment-focused by design.

The Dockerfile uses `public.ecr.aws/nginx/nginx:1.25-alpine` as a single stage — copying `dist/` directly into the nginx web root. Pulling from AWS ECR Public instead of Docker Hub avoids unauthenticated pull rate limits (429 errors) when building inside AWS CodeBuild. Final image size is approximately 25MB.

A custom `nginx.conf` is included alongside the Dockerfile. This is required for React Router: without the `try_files` fallback directive, any client-side route (e.g. `/tasks`) returns a 404 because nginx looks for a real file at that path. The config catches all unmatched paths and returns `index.html`, letting React handle routing client-side.

Additional nginx config details:
- `index.html` served with `no-cache` headers — ensures users always get the latest deploy
- Hashed static assets (JS/CSS) served with `immutable` 1-year cache — safe because filenames change on each build
- Gzip compression enabled for `text`, `js`, `css`, `svg`

```bash
# Build the image — explicitly targeting linux/amd64
# Required when building on Apple Silicon (ARM64) for AMD64 EKS nodes
docker build --platform linux/amd64 -t brain-tasks-app:latest .

# Run — maps container port 80 to localhost 3000
docker run -p 3000:80 brain-tasks-app:latest

# Verify
curl -I http://localhost:3000
# Expected: HTTP/1.1 200 OK
```

---

##  Phase 2 — Amazon ECR

Images are pushed to a private ECR repository and tagged with the Git commit SHA for traceability.

```bash
# Create ECR repository (one-time) with vulnerability scanning enabled
aws ecr create-repository \
  --repository-name brain-tasks-app \
  --region us-east-1 \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=Project,Value=brain-tasks-app

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS \
    --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Tag and push
docker tag brain-tasks-app:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest

# Verify image exists
aws ecr list-images --repository-name brain-tasks-app --region us-east-1
```

---

##  Phase 3 — Kubernetes on AWS EKS

### Cluster Setup

```bash
# Create EKS cluster with managed node group and autoscaling bounds
eksctl create cluster \
  --name brain-tasks-cluster \
  --region us-east-1 \
  --nodegroup-name standard-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed

# Verify nodes are Ready
kubectl get nodes
```

### Kubernetes Manifests

#### `k8s/deployment.yaml`
#### `K8s/service.yaml'

```bash
# Deploy to EKS
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Watch pods come up
kubectl get pods -w

# Get LoadBalancer URL
kubectl get service brain-tasks-service
```

---

##  Phase 4 — CI/CD Pipeline

### IAM Setup

Two IAM roles are required before CodeBuild and CodePipeline can function.

**CodeBuild service role** (`CodeBuildBrainTasksRole`) needs:
- Custom policy: ECR push, `eks:DescribeCluster`, CloudWatch logs
- `AmazonS3FullAccess` — read pipeline artifacts bucket
- `AmazonElasticContainerRegistryPublicReadOnly` — pull base images from ECR Public without rate limits

**CodePipeline service role** (`CodePipelineBrainTasksRole`) needs:
- `AWSCodePipeline_FullAccess`
- `AWSCodeBuildAdminAccess`
- `AmazonS3FullAccess`

**EKS `aws-auth` ConfigMap** must include the CodeBuild role so `kubectl` commands work inside the build:

```bash
eksctl create iamidentitymapping \
  --cluster brain-tasks-cluster \
  --region us-east-1 \
  --arn arn:aws:iam::<ACCOUNT_ID>:role/CodeBuildBrainTasksRole \
  --group system:masters \
  --username codebuild
```
Without this step, kubectl set image inside CodeBuild returns 403 from EKS even with valid AWS credentials — EKS has its own access control layer separate from IAM.

> **Note:** `runtime-versions: docker: 20` must NOT be declared in CodeBuild `standard:7.0` — Docker is pre-installed and declaring it causes a `YAML_FILE_ERROR`.

### CodePipeline Structure

| Stage | Provider | Action |
|---|---|---|
| Source | GitHub (v1 OAuth) | Trigger on push to `main` |
| Build + Deploy | AWS CodeBuild | Runs full `buildspec.yml` — build, push ECR, deploy to EKS |

> **Note on GitHub integration:** This project uses GitHub provider v1 with a personal access token stored in CodePipeline's encrypted config. The current AWS-recommended approach is CodeStar Connections (`aws codestar-connections`), which uses OAuth app authorization without storing personal tokens. A production setup would use this instead.

---

##  Phase 5 — Monitoring with CloudWatch

CloudWatch captures logs at every stage of the pipeline.

| Log Source | Log Group |
|---|---|
| CodeBuild build logs | `/aws/codebuild/brain-tasks-build` |
| EKS control plane | `/aws/eks/brain-tasks-cluster/cluster` |
| Application container logs | Accessible via `kubectl logs` |

```bash
# Tail live CodeBuild logs
aws logs tail /aws/codebuild/brain-tasks-build --follow

# Check pod logs directly
kubectl logs -l app=brain-tasks-app --tail=50
```

EKS control plane logging enabled for: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`.

---

##  Live Application

**LoadBalancer URL:** `http://a103d6d49925745cf9cb64f395a10155-2117866487.us-east-1.elb.amazonaws.com:3000`

```bash
# Retrieve LoadBalancer DNS at any time
kubectl get service brain-tasks-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

##  IAM Summary

| Role | Policies Attached |
|---|---|
| `CodeBuildBrainTasksRole` | Custom ECR+EKS policy · `AmazonS3FullAccess` · `AmazonElasticContainerRegistryPublicReadOnly` |
| `CodePipelineBrainTasksRole` | `AWSCodePipeline_FullAccess` · `AWSCodeBuildAdminAccess` · `AmazonS3FullAccess` |
| EKS `aws-auth` | `CodeBuildBrainTasksRole` mapped to `system:masters` via `eksctl create iamidentitymapping` |

---

##  Screenshots

| Screenshot | Description |
|---|---|
| `codepipeline.png` | Successful pipeline execution — Source + Build stages |
| `eks-pods.png` | 3 pods running across EKS nodes |
| `app-running.png` | React app live via LoadBalancer URL |

---


## 🔭 Possible Extensions

| Enhancement | Tool |
|---|---|
| Infrastructure as Code | Terraform (EKS cluster, ECR, IAM) |
| GitOps delivery | ArgoCD |
| Helm-based deployment | Helm charts replacing raw YAML |
| Blue/Green or Canary deployments | AWS CodeDeploy or Flagger |
| Metrics + alerting | Prometheus + Grafana on EKS |
| Secrets management | AWS Secrets Manager + External Secrets Operator |
| GitHub integration | CodeStar Connections replacing OAuth token |

---

## Author

**Preethi Chandrasekaran  DevOps / Cloud Engineer**
Specialization: AWS · Kubernetes · CI/CD · Container Infrastructure

---

