# 🚀 Brain Tasks App — Production DevOps Pipeline on AWS

> **End-to-end CI/CD pipeline**: React app → Docker → Amazon ECR → Kubernetes (EKS) → automated via AWS CodePipeline + CodeBuild → monitored with CloudWatch.

---

## 📌 What This Project Demonstrates

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

## 🏗 Architecture

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

## 🗂 Repository Structure

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

## 🐳 Phase 1 — Dockerize the Application

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

## 📦 Phase 2 — Amazon ECR

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

## ☸️ Phase 3 — Kubernetes on AWS EKS

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
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
```

#### `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: brain-tasks-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "classic"
spec:
  selector:
    app: brain-tasks-app
  type: LoadBalancer
  ports:
    - name: http
      protocol: TCP
      port: 3000
      targetPort: 80
```

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

## 🔄 Phase 4 — CI/CD Pipeline

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

Without this step, `kubectl set image` inside CodeBuild returns 403 from EKS even with valid AWS credentials — EKS has its own access control layer separate from IAM.

### `buildspec.yml`

```yaml
version: 0.2

env:
  variables:
    AWS_DEFAULT_REGION: us-east-1
    AWS_ACCOUNT_ID: "<ACCOUNT_ID>"
    ECR_REPO_URI: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app
    EKS_CLUSTER_NAME: brain-tasks-cluster
    DEPLOYMENT_NAME: brain-tasks-app
    CONTAINER_NAME: brain-tasks-app

phases:
  install:
    commands:
      - echo "Installing kubectl..."
      - curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
      - chmod +x kubectl
      - mv kubectl /usr/local/bin/kubectl
      - kubectl version --client

  pre_build:
    commands:
      - echo "Logging in to Amazon ECR..."
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI

      - echo "Logging in to ECR Public to avoid Docker Hub rate limits..."
      - aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

      - echo "Setting image tag from commit SHA..."
      - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
      - IMAGE_TAG=${COMMIT_HASH:=latest}

      - echo "Updating kubeconfig for EKS cluster..."
      - aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name $EKS_CLUSTER_NAME

  build:
    commands:
      - echo "Building Docker image for linux/amd64..."
      - docker build --platform linux/amd64 -t $ECR_REPO_URI:latest .
      - docker tag $ECR_REPO_URI:latest $ECR_REPO_URI:$IMAGE_TAG

  post_build:
    commands:
      - echo "Pushing image to ECR..."
      - docker push $ECR_REPO_URI:latest
      - docker push $ECR_REPO_URI:$IMAGE_TAG

      - echo "Deploying to EKS..."
      - kubectl set image deployment/$DEPLOYMENT_NAME $CONTAINER_NAME=$ECR_REPO_URI:$IMAGE_TAG
      - kubectl rollout status deployment/$DEPLOYMENT_NAME --timeout=120s

      - echo "Deployment complete. Current pods:"
      - kubectl get pods -l app=brain-tasks-app
```

> **Note:** `runtime-versions: docker: 20` must NOT be declared in CodeBuild `standard:7.0` — Docker is pre-installed and declaring it causes a `YAML_FILE_ERROR`.

### CodePipeline Structure

| Stage | Provider | Action |
|---|---|---|
| Source | GitHub (v1 OAuth) | Trigger on push to `main` |
| Build + Deploy | AWS CodeBuild | Runs full `buildspec.yml` — build, push ECR, deploy to EKS |

> **Note on GitHub integration:** This project uses GitHub provider v1 with a personal access token stored in CodePipeline's encrypted config. The current AWS-recommended approach is CodeStar Connections (`aws codestar-connections`), which uses OAuth app authorization without storing personal tokens. A production setup would use this instead.

---

## 📊 Phase 5 — Monitoring with CloudWatch

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

## 🌐 Live Application

**LoadBalancer URL:** `http://a103d6d49925745cf9cb64f395a10155-2117866487.us-east-1.elb.amazonaws.com:3000`

```bash
# Retrieve LoadBalancer DNS at any time
kubectl get service brain-tasks-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## 🔐 IAM Summary

| Role | Policies Attached |
|---|---|
| `CodeBuildBrainTasksRole` | Custom ECR+EKS policy · `AmazonS3FullAccess` · `AmazonElasticContainerRegistryPublicReadOnly` |
| `CodePipelineBrainTasksRole` | `AWSCodePipeline_FullAccess` · `AWSCodeBuildAdminAccess` · `AmazonS3FullAccess` |
| EKS `aws-auth` | `CodeBuildBrainTasksRole` mapped to `system:masters` via `eksctl create iamidentitymapping` |

---

## 📸 Screenshots

| Screenshot | Description |
|---|---|
| `codepipeline.png` | Successful pipeline execution — Source + Build stages |
| `eks-pods.png` | 3 pods running across EKS nodes |
| `app-running.png` | React app live via LoadBalancer URL |

---

## 🎯 Key Technical Decisions

**Why `nginx:alpine` instead of a Node-based image?**
The upstream repo ships pre-compiled `dist/` output — no Node.js runtime is needed to serve static files. `nginx:alpine` is purpose-built for this: it handles HTTP, compression, caching headers, and high concurrency with a ~25MB footprint. Running a Node server to serve static files would add unnecessary weight and attack surface.

**Why pull nginx from ECR Public instead of Docker Hub?**
Docker Hub enforces a 100 pulls/6hr rate limit for unauthenticated requests. CodeBuild pulls anonymously from Docker Hub by default, causing 429 errors mid-build. AWS ECR Public (`public.ecr.aws`) mirrors all official Docker Hub images with no rate limits inside AWS infrastructure.

**Why `--platform linux/amd64` in the Dockerfile and build command?**
The development machine runs Apple Silicon (ARM64). EKS `t3.medium` nodes run on AMD64 (x86_64). Building without specifying the platform produces an ARM64 image that cannot execute on EKS nodes — pods enter `CrashLoopBackOff` with `exec format error`. Pinning the platform at build time ensures architecture compatibility regardless of where the build runs.

**Why a custom `nginx.conf`?**
The default nginx config has no `try_files` fallback. React Router handles routing client-side, meaning paths like `/tasks` are not real files on disk. Without the fallback, nginx returns 404 for any route except `/`. The custom config catches all unmatched paths and returns `index.html`, letting React take over.

**Why tag images with commit SHA?**
Using `:latest` makes rollback untraceable. Tagging with `$COMMIT_HASH` means every deployment maps to a specific commit — rollback is a single `kubectl set image` pointing to the previous SHA.

**Why liveness and readiness probes?**
Without probes, Kubernetes cannot distinguish a crashed container from a running one. Readiness probes prevent traffic from reaching pods that haven't finished starting. Liveness probes trigger automatic restarts on hung containers.

**Why resource requests and limits?**
Without limits, a misbehaving pod can consume all node resources and cause noisy-neighbour failures across the cluster. Requests guarantee minimum allocation; limits enforce a hard cap.

**Why add CodeBuild role to EKS `aws-auth` ConfigMap?**
EKS maintains its own RBAC layer separate from IAM. Even with valid AWS credentials, `kubectl` calls inside CodeBuild are rejected with 403 unless the IAM role is explicitly mapped in `aws-auth`. This is the most commonly missed step when wiring CodeBuild to EKS.

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

## 👤 Author

**DevOps / Cloud Engineer**
Specialization: AWS · Kubernetes · CI/CD · Container Infrastructure

---

*Upstream application: [Brain-Tasks-App](https://github.com/Vennilavanguvi/Brain-Tasks-App) — forked and extended with full DevOps infrastructure.*
