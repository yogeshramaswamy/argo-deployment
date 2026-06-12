# Hayes Microservice Helm Charts

This repository contains Helm charts and Kubernetes manifests for deploying Hayes microservices to EKS clusters.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         EKS Cluster                              │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  kube-system namespace                                      │ │
│  │  └── AWS Load Balancer Controller (watches all Ingress)     │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  argocd namespace                                           │ │
│  │  ├── Argo CD (deployed via bootstrap/install.sh)            │ │
│  │  └── App-of-Apps (watches apps/<env>/ directory)            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  workload namespaces                                        │ │
│  │  └── Microservices (deployed by Argo from apps/<env>/)      │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Shared ALB (one per cluster)                               │ │
│  │  ├── host: hayes-argocd-stag.hayesinc.com → argocd-server  │ │
│  │  ├── host: app1.hayesinc.com → app1-service                │ │
│  │  └── path: /test-app → test-app-service                    │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
├── argocd/                      # Argo CD Helm chart (see argocd/README.md)
│   ├── Chart.yaml               # Helm chart with argo-cd dependency
│   ├── values.yaml              # Shared values with __PLACEHOLDER__ tokens
│   ├── README.md                # Detailed ArgoCD config documentation
│   └── templates/
│       ├── app-of-apps.yaml     # Two App-of-Apps (infra + workloads)
│       └── projects.yaml        # AppProjects (infra + workloads)
├── aws-lb-controller/           # AWS Load Balancer Controller chart
│   ├── Chart.yaml
│   └── values.yaml
├── apps/                        # Workload manifests (managed by Argo)
│   └── stag/
│       ├── infra/               # Infrastructure (ArgoCD ingress, LB controller)
│       │   ├── argocd-ingress.yaml
│       │   ├── alb-anchor-ingress.yaml
│       │   └── aws-lb-controller.yaml
│       └── app-workloads/       # Microservices
│           └── <service>.yaml   # Add new services here
├── bootstrap/
│   ├── install.sh               # Deploy script (install + upgrade)
│   └── envs/
│       ├── dev.env
│       ├── stag.env
│       └── prod.env
└── .gitignore                   # Excludes envs/, keys/, *.pem
```

## Quick Start

### Prerequisites

- Kubernetes 1.28+
- Helm 3.14+
- AWS CLI 2.x (with credentials configured)
- kubectl context for the target EKS cluster

### Deploy

```bash
# Deploy AWS LB Controller + Argo CD to staging
chmod +x bootstrap/install.sh
./bootstrap/install.sh stag

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Access UI via port-forward
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Open https://localhost:8080

# Or via domain (after DNS is configured)
# https://hayes-argocd-stag.hayesinc.com
```

### Upgrade

Same command — `install.sh` handles both install and upgrade:

```bash
./bootstrap/install.sh stag
```

### Dry Run

```bash
./bootstrap/install.sh stag --dry-run
```

## How It Works

### What the bootstrap script does

1. Switches kubectl context to the target cluster (using ARN)
2. Verifies cluster connectivity
3. Deploys AWS Load Balancer Controller (if not present, or upgrades)
4. Creates argocd namespace and Git repo credentials
5. Deploys Argo CD via Helm
6. Waits for pods to be ready

### What Argo CD manages

After bootstrap, Argo CD watches two folders via App-of-Apps:
- `apps/<env>/infra/` — Infrastructure (ingress, LB controller Application CR)
- `apps/<env>/app-workloads/` — Microservice Application CRs

### What Argo CD does NOT manage

- Itself (deployed via `bootstrap/install.sh`)
- AWS Load Balancer Controller Helm release (deployed via `bootstrap/install.sh`)

> For detailed ArgoCD configuration (auth, RBAC, projects, placeholders), see [argocd/README.md](argocd/README.md)

## Shared ALB (Single Load Balancer per Cluster)

All services share one ALB using the `alb.ingress.kubernetes.io/group.name` annotation. Each service creates its own Ingress in its own namespace.

### Adding a new service to the shared ALB

Create a file in `apps/stag/` with an Ingress using the same group name:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service-ingress
  namespace: my-service
  annotations:
    alb.ingress.kubernetes.io/group.name: symplr-hayes-stag-eks-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:952221970209:certificate/ecfa76d0-03d9-4d9c-b981-0f2cfc145e41
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
spec:
  ingressClassName: alb
  rules:
    - host: my-service.hayesinc.com        # Host-based routing
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

Or use path-based routing on an existing host:

```yaml
  rules:
    - host: hayes-argocd-stag.hayesinc.com
      http:
        paths:
          - path: /my-service              # Path-based routing
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

Then add a CNAME record in Route53 pointing to the ALB DNS name.

## DNS Setup (Route53)

For each new host, create a CNAME record:
- **Record name:** `my-service` (under `hayesinc.com`)
- **Type:** CNAME
- **Value:** `k8s-symplrhayesstagek-<id>.us-west-2.elb.amazonaws.com`

Get the ALB DNS name:
```bash
kubectl -n argocd get ingress argocd-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Authentication

Argo CD supports two login methods:
- **Admin:** username `admin` + auto-generated password
- **GitHub SSO:** via Dex OAuth connector (configured in `argocd/values.yaml`)

## Environment Configuration

| Env | Cluster | Domain | ALB Group |
|-----|---------|--------|-----------|
| dev | symplr-hayes-dev-eks-cluster | hayes-argocd-dev.hayesinc.com | symplr-hayes-dev-eks-alb |
| stag | symplr-hayes-stag-eks-cluster | hayes-argocd-stag.hayesinc.com | symplr-hayes-stag-eks-alb |
| prod | symplr-hayes-prod-eks-cluster | hayes-argocd.hayesinc.com | symplr-hayes-prod-eks-alb |

## Pre-requisites (Before Bootstrap)

### Subnet Tagging (Required)

The ALB Controller auto-discovers subnets via tags. Before running `bootstrap/install.sh`, tag your subnets:

**1. Find your public subnets:**
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
  --query "Subnets[?MapPublicIpOnLaunch==\`true\`].[SubnetId,AvailabilityZone]" \
  --output table --region us-west-2
```

**2. Tag public subnets (required for internet-facing ALBs):**
```bash
aws ec2 create-tags \
  --resources subnet-xxxxx subnet-yyyyy \
  --tags Key=kubernetes.io/role/elb,Value=1 \
  --region us-west-2
```

Without these tags, the ALB Controller will fail with: `couldn't auto-discover subnets: unable to resolve at least one subnet`

## Support

For issues or questions, contact the Hayes DevOps team.
