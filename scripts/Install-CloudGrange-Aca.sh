#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Install-CloudGrange-Aca.sh — install CloudGrange on Azure Container Apps (AB#9171, E9).
#
# This is the ACA delivery path's thin wrapper, and it is thin in the same sense as the
# Windows, Linux and appliance wrappers: it provisions the substrate and then hands over to
# the platform definition. Here the definition is iac/main.bicep rather than the Helm chart,
# because Container Apps cannot run Helm or Kubernetes manifests at all.
#
# What it does that an operator would otherwise have to do by hand:
#   * generates every bootstrap secret the platform needs, and NEVER asks for one. On a
#     re-run it reads each value back out of Key Vault instead of generating a new one, so a
#     redeploy does not rotate the database password out from under a running server or
#     invalidate the realm's client secret. This is the ACA equivalent of the chart's
#     secrets-bootstrap Job, which likewise generates once and never overwrites.
#   * gives the platform's managed identity the rights its own in-app updater needs, scoped
#     to the individual Container Apps and the single database server.
#   * sets the runtime contract the API reads: CLOUDGRANGE_RUNTIME=aca, the app names, the
#     update channel, the image tag and the platform version.
#
# Foundation updates do not exist on this path. Azure owns the host and the orchestration
# layer, so CLOUDGRANGE_FOUNDATION_MANAGED is false and the portal shows no Foundation card.
#
# Usage:
#   ./Install-CloudGrange-Aca.sh --owner-email ops@contoso.com [options]
#
# Options:
#   --owner-email <email>    Required. Used for the Owner tag and budget alerts.
#   --resource-group <name>  Resource group to create or reuse. Default: CAF-derived.
#   --location <region>      Default: eastus
#   --environment <env>      dev | test | stage | prod. Default: prod
#   --instance <nnn>         Default: 001
#   --version <tag>          Platform release to install (image tag). Default: read from
#                            the update channel's `latest`.
#   --update-channel <url>   https URL of the release channel. Default: the public preview
#                            channel.
#   --cost-center <name>     Default: Engineering
#   --business-unit <name>   Default: Engineering
#   --tag <k=v>              Extra tag; repeatable.
#   --no-governance          Skip Defender for Cloud and Azure Policy assignments. Both are
#                            SUBSCRIPTION-level changes that deleting the resource group does
#                            not undo, so they are off by default for anything but prod.
#   --what-if                Run `az deployment sub what-if` and stop.
#   --help
#
# Requires: az, jq, openssl, curl.

set -euo pipefail

LOCATION="eastus"
ENVIRONMENT="prod"
INSTANCE="001"
WORKLOAD="cloudgrange"
COST_CENTER="Engineering"
BUSINESS_UNIT="Engineering"
DATA_CLASSIFICATION="Internal"
CRITICALITY="High"
OWNER_EMAIL=""
RESOURCE_GROUP=""
VERSION=""
UPDATE_CHANNEL="https://pub-ab113af532ff44ef827c176e42118f17.r2.dev/channels/preview.json"
MODULE_CATALOG=""
GOVERNANCE="true"
WHATIF="false"
EXTRA_TAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner-email)     OWNER_EMAIL="$2";     shift 2 ;;
    --resource-group)  RESOURCE_GROUP="$2";  shift 2 ;;
    --location)        LOCATION="$2";        shift 2 ;;
    --environment)     ENVIRONMENT="$2";     shift 2 ;;
    --instance)        INSTANCE="$2";        shift 2 ;;
    --version)         VERSION="$2";         shift 2 ;;
    --update-channel)  UPDATE_CHANNEL="$2";  shift 2 ;;
    --module-catalog)  MODULE_CATALOG="$2";  shift 2 ;;
    --cost-center)     COST_CENTER="$2";     shift 2 ;;
    --business-unit)   BUSINESS_UNIT="$2";   shift 2 ;;
    --tag)             EXTRA_TAGS+=("$2");   shift 2 ;;
    --no-governance)   GOVERNANCE="false";   shift ;;
    --what-if)         WHATIF="true";        shift ;;
    --help|-h)         grep '^#' "$0" | sed 's/^# \?//' | sed -n '1,45p'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$OWNER_EMAIL" ]] || { echo "Error: --owner-email is required." >&2; exit 1; }

for cmd in az jq openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required." >&2; exit 1; }
done

case "$UPDATE_CHANNEL" in
  https://*) ;;
  # The trust model on every path is HTTPS plus a SHA-256 digest of the release manifest
  # (pmo/decisions-2026-09-18). A plain-http channel has no trust root at all, so refuse it
  # here rather than let the updater refuse it later, after the install.
  *) echo "Error: --update-channel must be an https URL (got: $UPDATE_CHANNEL)." >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/iac/main.bicep"
[[ -f "$TEMPLATE" ]] || { echo "Error: template not found at $TEMPLATE" >&2; exit 1; }

az account show >/dev/null 2>&1 || az login >/dev/null
SUBSCRIPTION="$(az account show --query id -o tsv)"

# ── Preflight: can this subscription actually create the database here? ──────
# Azure restricts PostgreSQL flexible-server provisioning per subscription and region, and
# the failure is both late and opaque: the deployment runs for ten minutes and then returns
# "ParameterOutOfRange: The value of the 'Version' should be in: []" — an empty list, because
# the whole region is closed to the subscription, not because the version is wrong. A real
# deployment failed exactly that way in eastus. Check it in two seconds instead.
PG_VERSION="${PG_VERSION:-16}"
pg_skus="$(az postgres flexible-server list-skus -l "$LOCATION" -o json 2>/dev/null || echo '[]')"
pg_reason="$(jq -r '[.[].reason // empty] | map(select(. != "")) | first // empty' <<<"$pg_skus")"
if [[ -n "$pg_reason" ]]; then
  echo "Error: Azure Database for PostgreSQL flexible server cannot be provisioned in '$LOCATION' with this subscription." >&2
  echo "  Azure says: $pg_reason" >&2
  echo "  Re-run with --location <region> in a region this subscription can use." >&2
  exit 1
fi
if ! jq -e --arg v "$PG_VERSION" '[.. | .supportedServerVersions? // empty | if type=="array" then (.[] | .name? // .) else . end] | index($v)' <<<"$pg_skus" >/dev/null 2>&1; then
  echo "Error: PostgreSQL $PG_VERSION is not offered in '$LOCATION'." >&2
  echo "  Offered: $(jq -r '[.. | .supportedServerVersions? // empty | if type=="array" then (.[] | .name? // .) else . end] | unique | join(", ")' <<<"$pg_skus")" >&2
  exit 1
fi

# ── Region code, mirroring the CAF table in main.bicep ───────────────────────
declare -A REGION_CODES=(
  [eastus]=eus [eastus2]=eus2 [westus]=wus [westus2]=wus2 [westus3]=wus3
  [centralus]=cus [northcentralus]=ncus [southcentralus]=scus [westcentralus]=wcus
  [northeurope]=neu [westeurope]=weu [uksouth]=uks [ukwest]=ukw
  [francecentral]=frc [germanywestcentral]=gwc [switzerlandnorth]=chn [swedencentral]=sec
  [australiaeast]=aue [australiasoutheast]=ause [southeastasia]=sea [eastasia]=ea
  [japaneast]=jpe [japanwest]=jpw [koreacentral]=krc [centralindia]=cin [southindia]=sin
  [canadacentral]=cac [canadaeast]=cae [brazilsouth]=brs [uaenorth]=uaen [southafricanorth]=san
)
REGION_CODE="${REGION_CODES[$LOCATION]:-${LOCATION:0:4}}"
[[ -n "$RESOURCE_GROUP" ]] || RESOURCE_GROUP="rg-${WORKLOAD}-${ENVIRONMENT}-${REGION_CODE}-${INSTANCE}"

# ── Resolve the release to install ───────────────────────────────────────────
# Defaulting to the channel's `latest` rather than a tag baked into this script is what stops
# the install docs going stale the way the Linux path's did: there is one place that decides
# what "current" means, and it is the channel.
if [[ -z "$VERSION" ]]; then
  echo "Reading the latest release from $UPDATE_CHANNEL ..."
  VERSION="$(curl -fsSL -A 'cloudgrange-installer-aca/1' "$UPDATE_CHANNEL" | jq -r '.latest.version // empty')"
  [[ -n "$VERSION" ]] || { echo "Error: could not read latest.version from $UPDATE_CHANNEL. Pass --version." >&2; exit 1; }
fi
[[ -n "$MODULE_CATALOG" ]] || MODULE_CATALOG="$(dirname "$UPDATE_CHANNEL" | sed 's#/channels$##')/modules/catalog.json"

# ── Key Vault name: deterministic from the resource group, so a re-run finds it ──
# The template derives its own default from uniqueString(resourceGroup().id), which this
# script cannot compute before the group exists. Passing an explicit name instead makes the
# vault findable on the second run, which is the whole basis of the generate-once rule below.
KV_HASH="$(printf '%s' "${SUBSCRIPTION}/${RESOURCE_GROUP}" | sha256sum | cut -c1-8)"
KEY_VAULT_NAME="kvcg${KV_HASH}${INSTANCE}"

# ── Bootstrap secrets: generate once, reuse for ever ─────────────────────────
# Read-then-generate, per secret. An operator is never prompted, and a redeploy never
# rotates a live credential. Values are only ever written to Key Vault by the template
# (as @secure() parameters), never echoed and never left in a file.
# Guarded by VAULT_EXISTS: asking Key Vault for a secret in a vault that does not exist yet
# resolves <vault>.vault.azure.net, which on a first install is a DNS miss the SDK retries
# for a long time — once per secret. On a first install there is nothing to read anyway.
kv_get() {
  [[ "${VAULT_EXISTS:-0}" == "1" ]] || return 0
  az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$1" --query value -o tsv 2>/dev/null || true
}
gen_password() {                       # 24 chars, complexity-safe for PostgreSQL
  printf '%sAa1!' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
}
gen_token() { openssl rand -hex 32; }
gen_key()   { openssl rand -base64 32; }

VAULT_EXISTS="$(az keyvault list --resource-group "$RESOURCE_GROUP" --query "[?name=='$KEY_VAULT_NAME'] | length(@)" -o tsv 2>/dev/null || echo 0)"
if [[ "$VAULT_EXISTS" == "1" ]]; then
  echo "Reusing the bootstrap secrets already in Key Vault $KEY_VAULT_NAME."
else
  echo "First install in $RESOURCE_GROUP — generating bootstrap secrets."
fi

PG_PASSWORD="$(kv_get 'cs-'"$ENVIRONMENT"'-core-db-password')"; [[ -n "$PG_PASSWORD" ]] || PG_PASSWORD="$(gen_password)"
MASTER_KEY="$(kv_get 'cloudgrange-master-key')";                 [[ -n "$MASTER_KEY" ]]  || MASTER_KEY="$(gen_key)"
KC_ADMIN_USER="$(kv_get 'cloudgrange-keycloak-admin-user')";     [[ -n "$KC_ADMIN_USER" ]] || KC_ADMIN_USER="kcadmin"
KC_ADMIN_PASSWORD="$(kv_get 'cloudgrange-keycloak-admin-password')"; [[ -n "$KC_ADMIN_PASSWORD" ]] || KC_ADMIN_PASSWORD="$(gen_password)"
KC_API_CLIENT_SECRET="$(kv_get 'cloudgrange-keycloak-api-client-secret')"; [[ -n "$KC_API_CLIENT_SECRET" ]] || KC_API_CLIENT_SECRET="$(gen_token)"
RELAY_TOKEN="$(kv_get 'cloudgrange-relay-enrollment-token')";    [[ -n "$RELAY_TOKEN" ]] || RELAY_TOKEN="$(gen_token)"
REALM_ADMIN_PASSWORD="$(kv_get 'cloudgrange-realm-admin-password')"; [[ -n "$REALM_ADMIN_PASSWORD" ]] || REALM_ADMIN_PASSWORD="$(gen_password)"

# ── Tags ─────────────────────────────────────────────────────────────────────
COMMON_TAGS="$(jq -n \
  --arg env "$ENVIRONMENT" --arg wl "$WORKLOAD" --arg cc "$COST_CENTER" \
  --arg owner "$OWNER_EMAIL" --arg bu "$BUSINESS_UNIT" \
  --arg dc "$DATA_CLASSIFICATION" --arg cr "$CRITICALITY" \
  '{Environment:$env, Workload:$wl, CostCenter:$cc, Owner:$owner, BusinessUnit:$bu, DataClassification:$dc, Criticality:$cr}')"
for kv in "${EXTRA_TAGS[@]:-}"; do
  [[ -z "$kv" ]] && continue
  k="${kv%%=*}"; v="${kv#*=}"
  # Azure tag keys are unique CASE-INSENSITIVELY, and the provider only says so during
  # preflight — after every parameter has been assembled. `--tag owner=…` alongside the
  # mandatory `Owner` tag failed a real deployment that way. Replace the existing key
  # rather than adding a second spelling of it.
  existing="$(jq -r --arg k "$k" 'keys[] | select(ascii_downcase == ($k | ascii_downcase))' <<<"$COMMON_TAGS" | head -1)"
  [[ -n "$existing" ]] && COMMON_TAGS="$(jq --arg k "$existing" 'del(.[$k])' <<<"$COMMON_TAGS")"
  COMMON_TAGS="$(jq --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$COMMON_TAGS")"
done

DEPLOY_NAME="cloudgrange-aca-$(date -u +%Y%m%d%H%M%S)"
ACTION="create"; [[ "$WHATIF" == "true" ]] && ACTION="what-if"

echo ""
echo "CloudGrange on Azure Container Apps"
echo "  subscription   : $SUBSCRIPTION"
echo "  resource group : $RESOURCE_GROUP"
echo "  location       : $LOCATION"
echo "  release        : $VERSION"
echo "  update channel : $UPDATE_CHANNEL"
echo "  key vault      : $KEY_VAULT_NAME"
echo "  governance     : $GOVERNANCE"
echo ""

# Secrets go through a parameter file on a 600-mode temp path rather than the command line,
# where they would be visible in the process table.
PARAMS_FILE="$(mktemp)"; chmod 600 "$PARAMS_FILE"
trap 'rm -f "$PARAMS_FILE"' EXIT
jq -n \
  --arg loc "$LOCATION" --arg env "$ENVIRONMENT" --arg inst "$INSTANCE" --arg wl "$WORKLOAD" \
  --arg rg "$RESOURCE_GROUP" --arg kvn "$KEY_VAULT_NAME" \
  --arg tag "$VERSION" --arg pv "$VERSION" --arg ch "$UPDATE_CHANNEL" --arg cat "$MODULE_CATALOG" \
  --arg pgu "cloudgrange" --arg pgp "$PG_PASSWORD" --arg mk "$MASTER_KEY" \
  --arg kcu "$KC_ADMIN_USER" --arg kcp "$KC_ADMIN_PASSWORD" --arg kcs "$KC_API_CLIENT_SECRET" \
  --arg rt "$RELAY_TOKEN" --arg rap "$REALM_ADMIN_PASSWORD" \
  --argjson tags "$COMMON_TAGS" \
  --argjson gov "$([[ "$GOVERNANCE" == "true" ]] && echo true || echo false)" \
  '{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0",
    parameters: {
      location:                 {value: $loc},
      environment:              {value: $env},
      instance:                 {value: $inst},
      workload:                 {value: $wl},
      resourceGroupName:        {value: $rg},
      keyVaultName:             {value: $kvn},
      commonTags:               {value: $tags},
      imageTag:                 {value: $tag},
      platformVersion:          {value: $pv},
      updateChannelUrl:         {value: $ch},
      moduleCatalogUrl:         {value: $cat},
      postgresAdminUser:        {value: $pgu},
      postgresAdminPassword:    {value: $pgp},
      masterKey:                {value: $mk},
      keycloakAdminUser:        {value: $kcu},
      keycloakAdminPassword:    {value: $kcp},
      keycloakApiClientSecret:  {value: $kcs},
      relayEnrollmentToken:     {value: $rt},
      realmAdminPassword:       {value: $rap},
      enableDefenderForCloud:   {value: $gov},
      enablePolicyAssignments:  {value: $gov},
      # The PgBouncer sidecar puts the API on localhost with SSL disabled and then makes
      # PgBouncer responsible for the TLS hop to Azure Database for PostgreSQL, which
      # enforces TLS. That hop has never been exercised on this path, and a pooler is not
      # what a single-replica deployment needs. The API connects to the flexible server
      # directly with SSL Mode=Require instead.
      enablePgBouncer:          {value: false}
    }
  }' > "$PARAMS_FILE"

az deployment sub "$ACTION" \
  --name "$DEPLOY_NAME" \
  --location "$LOCATION" \
  --template-file "$TEMPLATE" \
  --parameters "@$PARAMS_FILE"

if [[ "$WHATIF" == "true" ]]; then
  echo "what-if only — nothing was deployed."
  echo "Note: a clean what-if is not a clean deploy. Container App name length and several"
  echo "other provider checks only run on create."
  exit 0
fi

PORTAL_URL="$(az deployment sub show --name "$DEPLOY_NAME" --query 'properties.outputs.PORTAL_URL.value' -o tsv)"

cat <<EOF

CloudGrange $VERSION is deployed.

  Portal          : $PORTAL_URL
  Resource group  : $RESOURCE_GROUP
  Key Vault       : $KEY_VAULT_NAME

Next: open the portal and complete first-run setup. You create the first administrator
there; nothing was pre-created for you and no password was printed here.

Updates: Platform -> Updates -> Platform card. There is no Foundation card on this path;
Azure owns the host and the orchestration layer.

Before a Platform update the API takes an on-demand backup of the PostgreSQL flexible
server. Rolling back re-tags the Container Apps to the previous release, which Azure serves
from the previous revision. It does NOT restore the database: point-in-time restore on Azure
Database for PostgreSQL creates a NEW server and is an operator action. Schema changes made
by the newer release are not reversed by a rollback.
EOF
