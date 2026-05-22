# Hayes Microservice Helm Charts

This repository contains Helm charts for deploying Hayes microservices to Kubernetes clusters.

## Overview

This project manages Helm charts for all microservices in the Hayes ecosystem, providing standardized deployment configurations across different environments.

### Purpose

This repository serves as the centralized location for migrating and maintaining legacy Helm charts, converting them to the latest Helm chart standards and best practices for improved maintainability and compatibility.

## Repository Structure

```
├── charts/
│   └── [microservice-name]/    # Individual microservice charts
├── values/
│   └── [environment]/          # Environment-specific values
└── docs/                        # Documentation and guidelines
```

## Prerequisites

- Kubernetes 1.35+
- Helm 3.0+

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
