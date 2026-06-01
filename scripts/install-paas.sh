#!/usr/bin/env bash
# install-paas.sh — Deploy CloudSmith to Azure PaaS.
# Generates all secrets automatically. Requires: az CLI, jq, openssl.
#
# Usage:
#   ./install-paas.sh \
#     --owner-email "ops@contoso.com"
#
# Optional:
#   --location      centralus (default)
#   --environment   prod (default) | dev | test | stage
#   --cost-center   Engineering (default)
#   --instance      001 (default)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
LOCATION="centralus"
ENVIRONMENT="prod"
INSTANCE="001"
COST_CENTER="Engineering"
BUSINESS_UNIT="Engineering"
ADMIN_PASSWORD=""
OWNER_EMAIL=""
PARAMS_FILE="cloudsmith-deploy.json"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)        LOCATION="$2";        shift 2 ;;
    --environment)     ENVIRONMENT="$2";     shift 2 ;;
    --instance)        INSTANCE="$2";        shift 2 ;;
    --cost-center)     COST_CENTER="$2";     shift 2 ;;
    --business-unit)   BUSINESS_UNIT="$2";   shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2";  shift 2 ;;
    --owner-email)     OWNER_EMAIL="$2";     shift 2 ;;
    --params-file)     PARAMS_FILE="$2";     shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//' | head -20
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validate required inputs ──────────────────────────────────────────────────
if [[ -z "$OWNER_EMAIL" ]]; then
  echo "Error: --owner-email is required." >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

# ── Check prerequisites ───────────────────────────────────────────────────────
for cmd in az jq openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# ── Verify Azure login ────────────────────────────────────────────────────────
echo "Checking Azure login..."
if ! az account show &>/dev/null; then
  echo "Not logged in. Running: az login"
  az login
fi
SUBSCRIPTION=$(az account show --query id -o tsv)
echo "Using subscription: $SUBSCRIPTION"

# ── Auto-generate secrets ─────────────────────────────────────────────────────
echo "Generating secrets..."
MASTER_KEY=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
PG_PASSWORD="${PG_PASSWORD}Aa1!"   # ensure complexity requirements

IMAGE_TAG="v1.0.0"
DEPLOY_NAME="cloudsmith-$(date +%Y%m%d%H%M)"

# ── Write parameters file ─────────────────────────────────────────────────────
echo "Writing parameters to: $PARAMS_FILE"
cat > "$PARAMS_FILE" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "environment":           { "value": "$ENVIRONMENT" },
    "instance":              { "value": "$INSTANCE" },
    "imageTag":              { "value": "$IMAGE_TAG" },
    "postgresAdminUser":     { "value": "cloudsmith" },
    "postgresAdminPassword": { "value": "$PG_PASSWORD" },
    "masterKey":             { "value": "$MASTER_KEY" },
    "Owner":                 { "value": "$OWNER_EMAIL" },
    "BusinessUnit":          { "value": "$BUSINESS_UNIT" },
    "DataClassification":    { "value": "Internal" },
    "Criticality":           { "value": "High" },
    "CostCenter":            { "value": "$COST_CENTER" }
  }
}
EOF
echo ""
echo "  Parameters written to $PARAMS_FILE"
echo "  You can edit this file before deploying if you need custom values."
echo ""

# ── Download templates ────────────────────────────────────────────────────────
TEMPLATE_DIR="$(mktemp -d)"
trap "rm -rf $TEMPLATE_DIR" EXIT

echo "Downloading CloudSmith installer templates..."
curl -fsSL -o "$TEMPLATE_DIR/main.bicep" \
  "https://raw.githubusercontent.com/cloudsmith-cloud/cloudsmith-installer/main/iac/main.bicep"

# ── Deploy ────────────────────────────────────────────────────────────────────
echo ""
echo "Deploying CloudSmith to Azure..."
echo "  Environment : $ENVIRONMENT"
echo "  Location    : $LOCATION"
echo "  Image tag   : $IMAGE_TAG"
echo "  Deploy name : $DEPLOY_NAME"
echo ""

az deployment sub create \
  --name "$DEPLOY_NAME" \
  --location "$LOCATION" \
  --template-file "$TEMPLATE_DIR/main.bicep" \
  --parameters "@$PARAMS_FILE"

# ── Show outputs ──────────────────────────────────────────────────────────────
echo ""
echo "Deployment complete. Getting URLs..."
PORTAL_URL=$(az deployment sub show \
  --name "$DEPLOY_NAME" \
  --query "properties.outputs.portalUrl.value" -o tsv 2>/dev/null || echo "")
API_URL=$(az deployment sub show \
  --name "$DEPLOY_NAME" \
  --query "properties.outputs.apiUrl.value" -o tsv 2>/dev/null || echo "")

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  CloudSmith deployed successfully                    ║"
echo "╠══════════════════════════════════════════════════════╣"
if [[ -n "$PORTAL_URL" ]]; then
echo "║  Portal : $PORTAL_URL"
fi
if [[ -n "$API_URL" ]]; then
echo "║  API    : $API_URL"
fi
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Next: open the Portal URL and complete setup        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Keep $PARAMS_FILE — it contains your deployment configuration."
echo "The master key and passwords are stored in Azure Key Vault."
