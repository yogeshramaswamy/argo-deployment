# Argo CD Setup - Self-Managed on EKS

This document covers the complete setup of Argo CD on an EKS cluster using the **self-managed pattern** (Argo CD manages its own installation via GitOps).

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         EKS Cluster                              │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   argocd namespace                          │ │
│  │                                                            │ │
│  │   ┌──────────────┐    ┌─────────────────────────────────┐ │ │
│  │   │  Argo CD     │───▶│  Application: argocd            │ │ │
│  │   │  Controller  │    │  (self-manage - watches this     │ │ │
│  │   │              │    │   repo's argocd/ directory)      │ │ │
│  │   └──────────────┘    └─────────────────────────────────┘ │ │
│  │          │                                                 │ │
│  │          │            ┌─────────────────────────────────┐ │ │
│  │          └───────────▶│  Application: hayes-apps         │ │ │
│  │                       │  (watches this repo's apps/      │ │ │
│  │                       │   directory for all workloads)   │ │ │
│  │                       └─────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
         │
         │  Watches (Git poll / webhook)
         ▼
┌─────────────────────────┐
│   GitHub Repository      │
│   csm-evidenceanalysis-  │
│   helm-charts            │
│                          │
│   ├── argocd/            │  ◀── Argo CD manages itself from here
│   │   ├── Chart.yaml     │
│   │   ├── values.yaml    │
│   │   └── templates/     │
│   ├── apps/              │  ◀── All other workload Application CRs
│   └── bootstrap/         │  ◀── One-time install script
└─────────────────────────┘
```

## How It Works

1. **Bootstrap (one-time):** Run `bootstrap/install.sh` to perform the initial Helm install of Argo CD on the cluster.
2. **Self-manage:** The bootstrap installs Application CRs (`argocd-self-manage.yaml`) that tell Argo CD to watch this Git repo.
3. **Steady state:** All future changes to Argo CD (upgrades, config, RBAC) are made via Git commits to `argocd/values.yaml`. Argo CD detects the change and reconciles itself.
4. **App of Apps:** The `hayes-apps` Application watches the `apps/` directory. Drop any new Application CR there and Argo will deploy it.

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| kubectl | 1.28+ | Kubernetes CLI |
| Helm | 3.14+ | Package manager |
| AWS CLI | 2.x | EKS auth |
| argocd CLI | 2.14+ | (Optional) Argo CD management |

Ensure your `kubectl` context points to the target EKS cluster:

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
kubectl config current-context
```

---

## Step-by-Step Installation

### Step 1: Update Configuration

Before running anything, update the following placeholders:

| File | Placeholder | Replace With |
|------|-------------|--------------|
| `argocd/values.yaml` | `hayes-argocd-stag.hayesinc.com` | Your actual Argo CD domain |
| `argocd/values.yaml` | ACM certificate ARN | Your AWS ACM cert ARN |
| `argocd/templates/argocd-self-manage.yaml` | `symplr-software/csm-evidenceanalysis-helm-build.git` | Your actual Git repo URL |
| `argocd/templates/app-of-apps.yaml` | `symplr-software/csm-evidenceanalysis-helm-build.git` | Your actual Git repo URL |

### Step 2: Bootstrap Argo CD

```bash
chmod +x bootstrap/install.sh
./bootstrap/install.sh
```

This will:
- Create the `argocd` namespace
- Add the Argo Helm repo
- Install Argo CD via Helm
- Wait for pods to become ready

### Step 3: Get Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### Step 4: Access the UI

**Option A - Port Forward (quick test):**
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Open https://localhost:8080
# Login: admin / <password from step 3>
```

**Option B - Via Ingress (production):**
Once your ALB ingress is configured and DNS is pointed, access via your domain (e.g., `https://hayes-argocd-stag.hayesinc.com`).

### Step 5: Verify Self-Management

After login, you should see two Applications in the UI:
- **argocd** — Argo CD managing itself (Healthy/Synced)
- **hayes-apps** — App of Apps for all other workloads

If the `argocd` Application shows "OutOfSync", click **Sync** once to trigger the initial reconciliation.

### Step 6: Push to Git Remote

```bash
git add .
git commit -m "Add Argo CD self-managed setup"
git push origin main
```

Once pushed, Argo CD will detect the repo and begin self-managing.

---

## Day-2 Operations

### Upgrading Argo CD

1. Edit `argocd/Chart.yaml` — bump the `argo-cd` dependency version
2. Edit `argocd/values.yaml` — adjust values if needed for the new version
3. Commit and push to `main`
4. Argo CD will auto-sync and upgrade itself

### Adding a New Microservice

Create an Application CR in `apps/`:

```yaml
# apps/my-service.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/symplr-software/csm-evidenceanalysis-helm-build.git
    targetRevision: main
    path: charts/my-service
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Commit and push — Argo CD will detect and deploy it automatically.

### Connecting a Private Git Repository

```bash
# Using HTTPS + token
kubectl -n argocd create secret generic repo-creds \
  --from-literal=url=https://github.com/symplr-software/csm-evidenceanalysis-helm-build.git \
  --from-literal=username=git \
  --from-literal=password=<GITHUB_PAT> \
  --from-literal=type=git

kubectl -n argocd label secret repo-creds argocd.argoproj.io/secret-type=repository
```

Or use SSH:
```bash
kubectl -n argocd create secret generic repo-creds-ssh \
  --from-literal=url=git@github.com:symplr-software/csm-evidenceanalysis-helm-build.git \
  --from-file=sshPrivateKey=~/.ssh/id_ed25519 \
  --from-literal=type=git

kubectl -n argocd label secret repo-creds-ssh argocd.argoproj.io/secret-type=repository
```

---

## Emergency Recovery

If Argo CD deploys a broken configuration and can't self-heal:

```bash
# Use the bootstrap script in recovery mode
./bootstrap/install.sh --recovery
```

This runs `helm upgrade` directly, bypassing the broken Argo CD state.

---

## AWS Load Balancer Controller

The LB Controller is managed by Argo CD via the `aws-lb-controller/` chart. It requires an IAM Role for Service Account (IRSA) created in the Terraform repo (`csm-evidenceanalysis-terraform-build`).

### IAM Role Details

| Field | Naming Convention |
|-------|-------------------|
| Name | `{cluster_name}-lb-controller-role` |
| ARN | `arn:aws:iam::{account_number}:role/{cluster_name}-lb-controller-role` |

For the staging cluster:

| Field | Value |
|-------|-------|
| Cluster Name | `symplr-hayes-stag-eks-cluster` |
| Role Name | `symplr-hayes-stag-eks-cluster-lb-controller-role` |
| Role ARN | `arn:aws:iam::952221970209:role/symplr-hayes-stag-eks-cluster-lb-controller-role` |

### How to get the Role ARN

```bash
# From AWS CLI
aws iam get-role --role-name {cluster_name}-lb-controller-role --query 'Role.Arn' --output text

# Example
aws iam get-role --role-name symplr-hayes-stag-eks-cluster-lb-controller-role --query 'Role.Arn' --output text
```

### Where to configure

Update the Role ARN in `aws-lb-controller/values.yaml`:

```yaml
aws-load-balancer-controller:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::{account_number}:role/{cluster_name}-lb-controller-role
```

### IAM Role is created in Terraform

The IAM role and policy live in the IaC repo: `csm-evidenceanalysis-terraform-build`

The role needs:
- Trust policy: OIDC provider of the EKS cluster
- Service account: `kube-system:aws-load-balancer-controller`
- Attached policy: [Official AWS LB Controller IAM Policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json)

---

## File Structure Reference

```
csm-evidenceanalysis-helm-charts/
├── argocd/                          # Argo CD self-managed config
│   ├── Chart.yaml                   # Helm chart with argo-cd dependency
│   ├── values.yaml                  # All Argo CD configuration
│   └── templates/
│       ├── argocd-self-manage.yaml  # Application CR: Argo manages itself
│       └── app-of-apps.yaml         # Application CR: watches apps/ directory
├── apps/                            # Application CRs for workloads (watched by Argo)
│   ├── aws-lb-controller.yaml      # LB Controller Application
│   └── ingress.yaml                # Shared ALB Ingress Application
├── aws-lb-controller/              # AWS Load Balancer Controller chart
│   ├── Chart.yaml
│   └── values.yaml
├── ingress/                         # Shared ALB Ingress chart
│   ├── Chart.yaml
│   ├── values.yaml                  # Add new hosts here
│   └── templates/
│       └── ingress.yaml
├── bootstrap/
│   └── install.sh                   # One-time bootstrap script
├── charts/                          # Microservice Helm charts
└── docs/
    └── argocd-setup.md              # This document
```

---

## TODO (Future)

- [ ] Configure GitHub OAuth/OIDC via Dex for SSO login
- [ ] Set up username/team-based RBAC (replace admin-only access)
- [ ] Enable Argo CD Notifications (Slack/Teams integration)
- [ ] Add Argo CD Image Updater for automated image promotion
- [ ] Configure Argo CD Projects for multi-team isolation

---

## Troubleshooting

### Pods not starting
```bash
kubectl -n argocd get pods
kubectl -n argocd describe pod <pod-name>
kubectl -n argocd logs <pod-name>
```

### Application stuck in "Progressing"
```bash
argocd app get argocd --refresh
argocd app sync argocd --force
```

### Can't access UI
```bash
# Check if server pod is running
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server

# Check ingress
kubectl -n argocd get ingress

# Fallback to port-forward
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

### Reset admin password
```bash
# Generate bcrypt hash
BCRYPT_HASH=$(htpasswd -nbBC 10 "" "NewPassword123!" | tr -d ':\n' | sed 's/$2y/$2a/')

# Patch the secret
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"${BCRYPT_HASH}\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

# Restart server to pick up change
kubectl -n argocd rollout restart deployment argocd-server
```
