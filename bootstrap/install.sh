#!/bin/bash
# =============================================================================
# Argo CD Deploy Script (Multi-Cluster)
# =============================================================================
# Installs or upgrades Argo CD on an EKS cluster using Helm.
# This is the single entry point for all Argo CD deployments.
#
# Usage:
#   ./bootstrap/install.sh <env>
#   ./bootstrap/install.sh <env> --dry-run
#
# Examples:
#   ./bootstrap/install.sh dev
#   ./bootstrap/install.sh stag
#   ./bootstrap/install.sh prod
#   ./bootstrap/install.sh stag --dry-run
#
# Env files are loaded from: bootstrap/envs/<env>.env
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Defaults
NAMESPACE="argocd"
RELEASE_NAME="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
CHART_PATH="${REPO_ROOT}/argocd"
DRY_RUN=false

# =============================================================================
# Parse arguments
# =============================================================================
usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo "  ./bootstrap/install.sh <env> [options]"
    echo ""
    echo -e "${YELLOW}Environments:${NC}"
    echo "  dev       Dev cluster"
    echo "  stag      Staging cluster"
    echo "  prod      Production cluster"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --dry-run   Show what would be done without executing"
    echo ""
    echo -e "${YELLOW}Env files:${NC}"
    echo "  Config is loaded from: bootstrap/envs/<env>.env"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./bootstrap/install.sh dev"
    echo "  ./bootstrap/install.sh stag"
    echo "  ./bootstrap/install.sh prod"
    echo "  ./bootstrap/install.sh stag --dry-run"
    exit 1
}

# First argument must be the environment
if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

TARGET_ENV="$1"
shift

# Parse remaining options
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# =============================================================================
# Load env file
# =============================================================================
ENV_FILE="${SCRIPT_DIR}/envs/${TARGET_ENV}.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}ERROR: Env file not found: ${ENV_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}Available environments:${NC}"
    for f in "${SCRIPT_DIR}"/envs/*.env; do
        if [[ -f "$f" ]]; then
            echo "  - $(basename "$f" .env)"
        fi
    done
    exit 1
fi

# Source the env file
set -a
source "$ENV_FILE"
set +a

# Validate required variables from env file
for var in CLUSTER_NAME REGION ENV AWS_ACCOUNT_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}ERROR: ${var} is not set in ${ENV_FILE}${NC}"
        exit 1
    fi
done

# Build the cluster ARN for kubectl context
CLUSTER_ARN="arn:aws:eks:${REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

# =============================================================================
# Resolve values file
# Priority: values-{env}.yaml > values.yaml
# =============================================================================
if [[ -f "${CHART_PATH}/values-${ENV}.yaml" ]]; then
    VALUES_FILE="${CHART_PATH}/values-${ENV}.yaml"
else
    VALUES_FILE="${CHART_PATH}/values.yaml"
fi

if [[ ! -f "$VALUES_FILE" ]]; then
    echo -e "${RED}ERROR: Values file not found: ${VALUES_FILE}${NC}"
    exit 1
fi

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Argo CD Deploy                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Env file:    ${GREEN}${ENV_FILE}${NC}"
echo -e "  Cluster:     ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  Region:      ${GREEN}${REGION}${NC}"
echo -e "  Environment: ${GREEN}${ENV}${NC}"
echo -e "  Values:      ${GREEN}${VALUES_FILE}${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY RUN] Would execute the following steps:${NC}"
    echo "  1. kubectl config use-context ${CLUSTER_ARN}"
    echo "  2. kubectl create namespace ${NAMESPACE}"
    echo "  3. Create repo-creds secret (GitHub PAT for private repo access)"
    echo "  4. helm repo add argo https://argoproj.github.io/argo-helm"
    echo "  5. helm dependency build ${CHART_PATH}"
    echo "  6. helm upgrade --install ${RELEASE_NAME} ${CHART_PATH} --values ${VALUES_FILE}"
    echo "  7. Wait for argocd-server rollout"
    echo ""
    echo -e "${YELLOW}[DRY RUN] No changes were made.${NC}"
    exit 0
fi

# Step 1: Verify prerequisites
echo -e "${YELLOW}[1/7] Verifying prerequisites...${NC}"

for cmd in kubectl helm aws; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}ERROR: ${cmd} not found. Please install it first.${NC}"
        exit 1
    fi
done
echo -e "  ${GREEN}✓${NC} kubectl, helm, aws CLI found"

# Step 2: Set kubectl context using cluster ARN
echo -e "${YELLOW}[2/7] Switching kubectl context to: ${CLUSTER_ARN}...${NC}"
kubectl config use-context "${CLUSTER_ARN}"

CURRENT_CONTEXT=$(kubectl config current-context)
echo -e "  Context: ${GREEN}${CURRENT_CONTEXT}${NC}"

# Verify cluster connectivity by listing nodes
echo -e "  Verifying cluster connectivity..."
if ! kubectl get nodes --no-headers 2>/dev/null; then
    echo -e "${RED}ERROR: Cannot connect to cluster. Check your kubeconfig and credentials.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Cluster reachable"
echo ""
read -p "  Proceed with deployment on this cluster? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

# Step 3: Create namespace
echo -e "${YELLOW}[3/7] Creating namespace '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Step 4: Configure Git repo credentials (PAT)
echo -e "${YELLOW}[4/7] Configuring Git repo credentials...${NC}"
if kubectl -n "${NAMESPACE}" get secret repo-creds &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} repo-creds secret already exists, skipping"
else
    if [[ -z "${GITHUB_PAT:-}" ]]; then
        echo -e "${RED}ERROR: GITHUB_PAT is not set in ${ENV_FILE}${NC}"
        echo -e "${YELLOW}HINT: Add your PAT to ${ENV_FILE}:${NC}"
        echo -e "  GITHUB_PAT=ghp_xxxxxxxxxxxx"
        exit 1
    fi

    kubectl -n "${NAMESPACE}" create secret generic repo-creds \
        --from-literal=url=https://github.com/yogeshramaswamy/argo-deployment.git \
        --from-literal=username=git \
        --from-literal=password="${GITHUB_PAT}" \
        --from-literal=type=git

    kubectl -n "${NAMESPACE}" label secret repo-creds argocd.argoproj.io/secret-type=repository

    echo -e "  ${GREEN}✓${NC} repo-creds secret created"
fi

# Step 5: Add Argo Helm repo
echo -e "${YELLOW}[5/7] Adding Argo Helm repository...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Step 6: Build dependencies and deploy
echo -e "${YELLOW}[6/7] Building Helm chart dependencies...${NC}"
helm dependency build "${CHART_PATH}"

echo -e "${YELLOW}[7/7] Deploying Argo CD (env: ${ENV})...${NC}"
echo -e "  This may take a few minutes while pods start up..."
HELM_OUTPUT=$(helm upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 5m 2>&1) || { echo -e "${RED}ERROR: Helm deploy failed${NC}"; echo "$HELM_OUTPUT" | grep -i "error"; exit 1; }

# Show only the meaningful output
echo "$HELM_OUTPUT" | grep -E "^(NAME|LAST DEPLOYED|NAMESPACE|STATUS|REVISION)" | while read -r line; do
    echo -e "  ${GREEN}${line}${NC}"
done
echo -e "  ${GREEN}✓${NC} Helm deploy complete"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Deploy Complete!                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Cluster:     ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  Environment: ${GREEN}${ENV}${NC}"
echo -e "  Namespace:   ${GREEN}${NAMESPACE}${NC}"
echo ""
echo -e "  ${YELLOW}Get admin password:${NC}"
echo "    kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
echo ""
echo -e "  ${YELLOW}Port-forward to access UI:${NC}"
echo "    kubectl -n ${NAMESPACE} port-forward svc/argocd-server 8080:443"
echo "    Then open: https://localhost:8080"
echo ""
echo -e "  ${YELLOW}Login via CLI:${NC}"
echo "    argocd login localhost:8080 --username admin --password <password> --insecure"
echo ""
echo -e "  ${YELLOW}To upgrade Argo CD later:${NC}"
echo "    1. Edit argocd/values.yaml or argocd/Chart.yaml"
echo "    2. Run: ./bootstrap/install.sh ${ENV}"
echo ""
