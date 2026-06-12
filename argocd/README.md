# ArgoCD Configuration

Helm wrapper chart that deploys ArgoCD on EKS using the official [argo-cd](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd) chart as a dependency.

## Architecture

```
bootstrap/install.sh        # Single entry point for install/upgrade
argocd/
  Chart.yaml                # Wrapper chart (depends on argo-cd 7.8.x)
  values.yaml               # Config with __PLACEHOLDER__ tokens
  templates/
    projects.yaml           # AppProjects: infra + workloads
    app-of-apps.yaml        # Two App-of-Apps (infra + workloads)
```

## How It Works

1. **Bootstrap script** (`bootstrap/install.sh <env>`) loads secrets from `bootstrap/envs/<env>.env`
2. **Placeholders** in `values.yaml` (`__ARGOCD_URL__`, `__GITHUB_APP_CLIENT_ID__`) are substituted via `sed` at deploy time
3. **Secrets** (GitHub App private key, client secret, webhook secret) are created as Kubernetes secrets directly via `kubectl` — never stored in Git
4. **Helm deploys** ArgoCD with the rendered values file
5. **Helm hooks** create AppProjects and App-of-Apps after CRDs are available

## Components

| Component | Details |
|-----------|---------|
| Chart | `argo-cd` 7.8.x from argoproj helm repo |
| Server | 2 replicas, runs in `--insecure` mode (TLS terminated at ALB) |
| Repo Server | 2 replicas |
| Controller | 1 replica |
| Redis | Single instance (non-HA) |
| ApplicationSet | 2 replicas |
| Notifications | Disabled |

## Authentication

### Repo Access (cloning)

Uses a **GitHub App** for authenticating to `symplr-software` org repos:
- App ID + Installation ID + Private Key stored in `repo-creds` Kubernetes secret
- Labeled with `argocd.argoproj.io/secret-type=repo-creds` for auto-discovery

### SSO (Dex + GitHub)

Uses the same GitHub App's OAuth flow for user login:
- Client ID injected into `values.yaml` via placeholder
- Client Secret stored in `argocd-secret` under key `dex.github.clientSecret`
- Scoped to `symplr-software` org, team `csm-argocd-admins`

## RBAC

| Group | Role |
|-------|------|
| `symplr-software:csm-argocd-admins` | `role:admin` |
| Everyone else | `role:readonly` |

## AppProjects

### `infra`
- Full cluster access (all namespaces, all resource types)
- Source repos: helm-build repo, eks-charts, argo-helm
- Used for: LB Controller, ingress configs, cluster-level resources

### `workloads`
- Namespace-scoped only (no cluster resources)
- Source repos: all `symplr-software/*` repos
- Blocked: ResourceQuota, LimitRange (managed by infra)

## App-of-Apps

Two parent Applications deployed via Helm hooks:

| Name | Path | Project | Hook Weight |
|------|------|---------|-------------|
| `hayes-infra` | `apps/<env>/infra/` | infra | 0 |
| `hayes-app-workloads` | `apps/<env>/app-workloads/` | workloads | 1 |

Both have automated sync with prune and self-heal enabled.

## Ingress

ArgoCD's built-in ingress is **disabled**. Instead, a standalone Ingress resource lives in `apps/<env>/infra/argocd-ingress.yaml` and joins the shared ALB via `alb.ingress.kubernetes.io/group.name`.

This keeps ALB configuration as a standard Kubernetes manifest managed by ArgoCD itself.

## Placeholders

| Placeholder | Source Variable | Example |
|-------------|----------------|---------|
| `__ARGOCD_URL__` | `ARGOCD_URL` | `https://hayes-argocd-<env>.hayesinc.com` |
| `__GITHUB_APP_CLIENT_ID__` | `GITHUB_APP_CLIENT_ID` | Per-environment GitHub App Client ID |

## Env File

Located at `bootstrap/envs/<env>.env` (gitignored). Required variables:

```
CLUSTER_NAME=symplr-hayes-stag-eks-cluster
REGION=us-west-2
ENV=stag
AWS_ACCOUNT_ID=952221970209
ARGOCD_URL=https://hayes-argocd-stag.hayesinc.com
GITHUB_APP_ID=<app-id>
GITHUB_APP_INSTALLATION_ID=<installation-id>
GITHUB_APP_CLIENT_ID=<client-id>
GITHUB_APP_CLIENT_SECRET=<client-secret>
GITHUB_APP_WEBHOOK_SECRET=<webhook-secret>
GITHUB_APP_PRIVATE_KEY_PATH=./bootstrap/keys/github-app-stag.pem
```

## Usage

```bash
# Deploy / upgrade staging
./bootstrap/install.sh stag

# Dry run (shows steps without executing)
./bootstrap/install.sh stag --dry-run

# Deploy other environments
./bootstrap/install.sh dev
./bootstrap/install.sh prod
```

## Design Decisions

- **No self-management**: ArgoCD does NOT manage its own Helm release. The bootstrap script is the single source of truth for install/upgrade. This avoids circular dependency issues between Helm hooks and ArgoCD's sync engine.
- **Shared ALB**: One ALB per cluster using `group.name` annotation. Services add their own Ingress to join the ALB. An anchor ingress keeps the ALB alive.
- **Intermediary CNAME**: All service CNAMEs point to `alb-symplr-hayes-stag-eks.hayesinc.com` which points to the actual ALB DNS. Only one record to update if ALB changes.
- **Secrets out of Git**: Placeholders in values.yaml, real values in `.env` files and Kubernetes secrets.
