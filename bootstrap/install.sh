#!/bin/bash
# =============================================================================
# Argo CD Bootstrap Script (Multi-Cluster)
# =============================================================================
# Performs a ONE-TIME installation of Argo CD on any EKS cluster.
# After bootstrap, Argo CD manages itself via the self-manage Application CR.
#
# Usage:
#   ./bootstrap/install.sh <env>
#   ./bootstrap/install.sh <env> --recovery
#   ./bootstrap/install.sh <env> --dry-run
#
# Examples:
#   ./bootstrap/install.sh dev
#   ./bootstrap/install.sh stag
#   ./bootstrap/install.sh prod
#   ./bootstrap/install.sh stag --recovery
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
RECOVERY=false
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
    echo "  --recovery  Recovery mode - helm upgrade bypassing Argo"
    echo "  --dry-run   Show what would be done without executing"
    echo ""
    echo -e "${YELLOW}Env files:${NC}"
    echo "  Config is loaded from: bootstrap/envs/<env>.env"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./bootstrap/install.sh dev"
    echo "  ./bootstrap/install.sh stag"
    echo "  ./bootstrap/install.sh prod"
    echo "  ./bootstrap/install.sh stag --recovery"
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
        --recovery)
            RECOVERY=true
            shift
            ;;
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
for var in CLUSTER_NAME REGION ENV; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}ERROR: ${var} is not set in ${ENV_FILE}${NC}"
        exit 1
    fi
done

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
echo -e "${GREEN}║         Argo CD Bootstrap Installer          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Env file:    ${GREEN}${ENV_FILE}${NC}"
echo -e "  Cluster:     ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  Region:      ${GREEN}${REGION}${NC}"
echo -e "  Environment: ${GREEN}${ENV}${NC}"
echo -e "  Values:      ${GREEN}${VALUES_FILE}${NC}"
echo -e "  Recovery:    ${GREEN}${RECOVERY}${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY RUN] Would execute the following steps:${NC}"
    echo "  1. aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
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
echo -e "${YELLOW}[1/8] Verifying prerequisites...${NC}"

for cmd in kubectl helm aws; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}ERROR: ${cmd} not found. Please install it first.${NC}"
        exit 1
    fi
done
echo -e "  ${GREEN}✓${NC} kubectl, helm, aws CLI found"

# Step 2: Update kubeconfig for the target cluster
echo -e "${YELLOW}[2/8] Switching kubectl context to: ${CLUSTER_NAME}...${NC}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

CURRENT_CONTEXT=$(kubectl config current-context)
echo -e "  Context: ${GREEN}${CURRENT_CONTEXT}${NC}"
echo ""
read -p "  Proceed with installation on this cluster? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

# Step 3: Create namespace
echo -e "${YELLOW}[3/8] Creating namespace '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Step 4: Configure Git repo credentials (PAT)
echo -e "${YELLOW}[4/8] Configuring Git repo credentials...${NC}"
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
echo -e "${YELLOW}[5/8] Adding Argo Helm repository...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Step 6: Build dependencies
echo -e "${YELLOW}[6/8] Building Helm chart dependencies...${NC}"
helm dependency build "${CHART_PATH}"

# Step 7: Install/Upgrade Argo CD
echo -e "${YELLOW}[7/8] Installing Argo CD (env: ${ENV})...${NC}"
if [[ "$RECOVERY" == true ]]; then
    echo -e "${YELLOW}  ⚠ RECOVERY MODE - bypassing Argo self-management${NC}"
    helm upgrade "${RELEASE_NAME}" "${CHART_PATH}" \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --wait \
        --timeout 5m
else
    helm upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --values "${VALUES_FILE}" \
        --wait \
        --timeout 5m
fi

# Step 8: Wait for pods
echo -e "${YELLOW}[8/8] Waiting for Argo CD pods to be ready...${NC}"
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-server --timeout=120s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=120s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-applicationcontroller --timeout=120s 2>/dev/null || true

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Bootstrap Complete!                   ║${NC}"
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
echo -e "  ${GREEN}Next steps:${NC}"
echo "    1. Push this repo to Git remote"
echo "    2. Argo CD detects the self-manage Application and takes over"
echo "    3. All future changes go through Git (GitOps)"
echo ""
