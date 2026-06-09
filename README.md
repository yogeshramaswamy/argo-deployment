# Hayes Microservice Helm Charts

This repository contains Helm charts for deploying Hayes microservices to Kubernetes clusters.

## Overview

This project manages Helm charts for all microservices in the Hayes ecosystem, providing standardized deployment configurations across different environments.

### Purpose

This repository serves as the centralized location for migrating and maintaining legacy Helm charts, converting them to the latest Helm chart standards and best practices for improved maintainability and compatibility.

## Repository Structure

```
├── argocd/                      # Argo CD self-managed configuration
│   ├── Chart.yaml               # Helm chart with argo-cd dependency
│   ├── values.yaml              # Argo CD configuration values
│   └── templates/               # Application CRs (self-manage + app-of-apps)
├── apps/                        # Application CRs for workloads (watched by Argo)
├── bootstrap/                   # One-time bootstrap install script
│   └── install.sh
├── charts/                      # Individual microservice Helm charts
│   └── [microservice-name]/
├── values/
│   └── [environment]/           # Environment-specific values
└── docs/                        # Documentation and guidelines
    └── argocd-setup.md          # Full Argo CD setup guide
```

## Quick Start - Argo CD

```bash
# 1. Update placeholders in argocd/values.yaml and templates
# 2. Bootstrap Argo CD
chmod +x bootstrap/install.sh
./bootstrap/install.sh

# 3. Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 4. Access UI
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

See [docs/argocd-setup.md](docs/argocd-setup.md) for the full guide.

## Prerequisites

- Kubernetes 1.28+
- Helm 3.14+
- AWS CLI 2.x (for EKS auth)

## Usage

### Installing a Chart

```bash
helm install <release-name> ./charts/<chart-name> -f values/<environment>/values.yaml
```

### Upgrading a Release

```bash
helm upgrade <release-name> ./charts/<chart-name> -f values/<environment>/values.yaml
```

### Validating Charts

```bash
helm lint ./charts/<chart-name>
```

## Charts

List your microservice charts here as they're added to the repository.

## Contributing

When adding new charts:
1. Create a new directory under `charts/`
2. Follow Helm best practices and standards
3. Include comprehensive README documentation
4. Test charts in dev environment before committing
5. Update this main README with chart information

## License

Add your license information here.

## Support

For issues or questions, contact the Hayes DevOps team.
