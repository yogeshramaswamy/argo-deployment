#!/bin/bash
# =============================================================================
# Argo CD Deploy Script (Multi-Cluster)
# =============================================================================
# Installs or upgrades AWS LB Controller + Argo CD on an EKS cluster using Helm.
# This is the single entry point for all deployments.
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
ARGOCD_NAMESPACE="argocd"
ARGOCD_RELEASE="argocd"
LB_NAMESPACE="kube-system"
LB_RELEASE="aws-lb-controller"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ARGOCD_CHART_PATH="${REPO_ROOT}/argocd"
LB_CHART_PATH="${REPO_ROOT}/aws-lb-controller"
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
# Resolve values files
# =============================================================================
if [[ -f "${ARGOCD_CHART_PATH}/values-${ENV}.yaml" ]]; then
    ARGOCD_VALUES="${ARGOCD_CHART_PATH}/values-${ENV}.yaml"
else
    ARGOCD_VALUES="${ARGOCD_CHART_PATH}/values.yaml"
fi

LB_VALUES="${LB_CHART_PATH}/values.yaml"

if [[ ! -f "$ARGOCD_VALUES" ]]; then
    echo -e "${RED}ERROR: Argo CD values file not found: ${ARGOCD_VALUES}${NC}"
    exit 1
fi

if [[ ! -f "$LB_VALUES" ]]; then
    echo -e "${RED}ERROR: LB Controller values file not found: ${LB_VALUES}${NC}"
    exit 1
fi

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         EKS Cluster Deploy                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Env file:    ${GREEN}${ENV_FILE}${NC}"
echo -e "  Cluster:     ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  Region:      ${GREEN}${REGION}${NC}"
echo -e "  Environment: ${GREEN}${ENV}${NC}"
echo -e "  Argo Values: ${GREEN}${ARGOCD_VALUES}${NC}"
echo -e "  LB Values:   ${GREEN}${LB_VALUES}${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY RUN] Would execute the following steps:${NC}"
    echo "  1. kubectl config use-context ${CLUSTER_ARN}"
    echo "  2. Verify cluster connectivity"
    echo "  3. Deploy AWS LB Controller (if not present)"
    echo "  4. Create argocd namespace"
    echo "  5. Create repo-creds secret"
    echo "  6. Deploy Argo CD via Helm"
    echo "  7. Wait for pods to be ready"
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

# Step 2: Set kubectl context using cluster ARN
echo -e "${YELLOW}[2/8] Switching kubectl context to: ${CLUSTER_ARN}...${NC}"
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

# Step 3: Deploy AWS Load Balancer Controller
echo -e "${YELLOW}[3/8] Deploying AWS Load Balancer Controller...${NC}"
if helm status "${LB_RELEASE}" -n "${LB_NAMESPACE}" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} AWS LB Controller already installed, upgrading..."
else
    echo -e "  Installing AWS LB Controller..."
fi

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm dependency build "${LB_CHART_PATH}" 2>/dev/null

LB_OUTPUT=$(helm upgrade --install "${LB_RELEASE}" "${LB_CHART_PATH}" \
    --namespace "${LB_NAMESPACE}" \
    --values "${LB_VALUES}" \
    --wait \
    --timeout 3m 2>&1) || { echo -e "${RED}ERROR: LB Controller deploy failed${NC}"; echo "$LB_OUTPUT" | grep -i "error"; exit 1; }

echo -e "  ${GREEN}✓${NC} AWS LB Controller deployed"

# Wait for controller pods to be ready
kubectl -n "${LB_NAMESPACE}" rollout status deployment/aws-lb-controller-aws-load-balancer-controller --timeout=60s 2>/dev/null || \
kubectl -n "${LB_NAMESPACE}" rollout status deployment/aws-load-balancer-controller --timeout=60s 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} LB Controller pods ready"

# Step 4: Create argocd namespace
echo -e "${YELLOW}[4/8] Creating namespace '${ARGOCD_NAMESPACE}'...${NC}"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Step 5: Configure Git repo credentials (PAT)
echo -e "${YELLOW}[5/8] Configuring Git repo credentials...${NC}"
if kubectl -n "${ARGOCD_NAMESPACE}" get secret repo-creds &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} repo-creds secret already exists, skipping"
else
    if [[ -z "${GITHUB_PAT:-}" ]]; then
        echo -e "${RED}ERROR: GITHUB_PAT is not set in ${ENV_FILE}${NC}"
        echo -e "${YELLOW}HINT: Add your PAT to ${ENV_FILE}:${NC}"
        echo -e "  GITHUB_PAT=ghp_xxxxxxxxxxxx"
        exit 1
    fi

    kubectl -n "${ARGOCD_NAMESPACE}" create secret generic repo-creds \
        --from-literal=url=https://github.com/yogeshramaswamy/argo-deployment.git \
        --from-literal=username=git \
        --from-literal=password="${GITHUB_PAT}" \
        --from-literal=type=git

    kubectl -n "${ARGOCD_NAMESPACE}" label secret repo-creds argocd.argoproj.io/secret-type=repository

    echo -e "  ${GREEN}✓${NC} repo-creds secret created"
fi

# Step 6: Add Argo Helm repo and build dependencies
echo -e "${YELLOW}[6/8] Adding Argo Helm repository...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm dependency build "${ARGOCD_CHART_PATH}"

# Step 7: Deploy Argo CD
echo -e "${YELLOW}[7/8] Deploying Argo CD (env: ${ENV})...${NC}"
echo -e "  This may take a few minutes while pods start up..."
HELM_OUTPUT=$(helm upgrade --install "${ARGOCD_RELEASE}" "${ARGOCD_CHART_PATH}" \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --values "${ARGOCD_VALUES}" \
    --wait \
    --timeout 5m 2>&1) || { echo -e "${RED}ERROR: Argo CD deploy failed${NC}"; echo "$HELM_OUTPUT" | grep -i "error"; exit 1; }

echo "$HELM_OUTPUT" | grep -E "^(NAME|LAST DEPLOYED|NAMESPACE|STATUS|REVISION)" | while read -r line; do
    echo -e "  ${GREEN}${line}${NC}"
done
echo -e "  ${GREEN}✓${NC} Argo CD deployed"

# Step 8: Wait for pods
echo -e "${YELLOW}[8/8] Waiting for Argo CD pods to be ready...${NC}"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=120s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=120s
echo -e "  ${GREEN}✓${NC} All pods ready"

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
echo -e "  LB Controller: ${GREEN}${LB_NAMESPACE}${NC}"
echo -e "  Argo CD:       ${GREEN}${ARGOCD_NAMESPACE}${NC}"
echo ""
echo -e "  ${YELLOW}Get admin password:${NC}"
echo "    kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
echo ""
echo -e "  ${YELLOW}Port-forward to access UI:${NC}"
echo "    kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server 8080:443"
echo "    Then open: https://localhost:8080"
echo ""
echo -e "  ${YELLOW}To upgrade later:${NC}"
echo "    ./bootstrap/install.sh ${ENV}"
echo ""
