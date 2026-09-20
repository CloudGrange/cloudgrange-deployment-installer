// Copyright 2026 CloudGrange Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudGrange PaaS (Model B) resource module — ADR-043 / ADR-044 / ADR-046 / ADR-047 / ADR-048.
//
// Wave 3 (AB#1599, AB#1600, AB#1667, AB#1668, AB#1669):
//   - KV purge protection enabled (HIGH security finding)
//   - PG password stored as KV secret; ACA references it via keyVaultUrl (CRITICAL finding)
//   - ACA health probes added to API + portal (HIGH security/reliability finding)
//   - HTTP scaling rules added (HIGH performance finding)
//   - LAW daily data cap (HIGH cost finding)
//   - PG geo-redundant backup parameter (MEDIUM reliability finding)
//   - PG public network access parameter (HIGH security finding)
//   - KV + PG diagnostic settings → LAW (MEDIUM security/opex finding)
//   - Azure Monitor alert rules module wired (MEDIUM opex finding)
//   - Azure Budget alert resource (MEDIUM cost finding)
//   - Defender for Cloud resources (LOW security finding)
//   - PgBouncer sidecar for API connection pooling (MEDIUM performance finding)
//   - ACA active revisions mode parameter (LOW reliability finding)
//   - appInsightsConnectionString marked @secure() (HIGH security finding)
//
// Security remediation (H1):
//   - CLOUDGRANGE_MASTER_KEY stored in KV (secret name: cloudgrange-master-key); ACA
//     references it via keyVaultUrl — never exposed as a plaintext ACA env var.
//
// Naming + tagging (ADR-048):
//   - Default names follow CAF pattern <type-abbr>-<workload>-<env>-<region>-<instance>
//   - Length-constrained types (Key Vault) drop separators and append a hash suffix
//   - Every resource accepts an explicit <resource>Name override and a <resource>Tags
//     object merged with commonTags + autoTags
//   - bringYourOwn parameter set lets callers supply existing LAW/AppI/UAMI/KV/ACA env
//     resource IDs and skip creation

@description('Azure region.')
param location string = resourceGroup().location

@description('Workload identifier. Used in CAF-pattern names.')
@minLength(2)
@maxLength(12)
param workload string

@description('Environment.')
@allowed([ 'dev', 'test', 'stage', 'prod' ])
param environment string

@description('Three-digit zero-padded instance number.')
@minLength(3)
@maxLength(3)
param instance string

@description('Three-letter Azure region code.')
param regionCode string

@description('CAF mandatory tag set + operator additions. Applied to every resource.')
param commonTags object

@description('Auto-injected tags (ManagedBy, DeployedAt). Applied to every resource.')
param autoTags object

// AB#9188 — default is 'latest' because it is the only tag that actually exists.
//
// This defaulted to 'main' on the reasoning that 'latest' floats unpredictably and 'main' always
// resolves to the most recent main-branch image. The reasoning is sound; the tag is not — nothing
// has ever published 'main' to ghcr.io/cloudgrange/*. Verified against the registry:
// cloudgrange-api:main and :v1.0.0 both return 404, :latest returns 200. So every ACA deployment
// that took the default failed to pull, which is why ACA has been quietly broken.
//
// The guidance still stands and is the reason this is only a default: CI should pass an explicit
// SHA or semver tag for stage/prod. Until versioned tags are actually published, a default that
// resolves beats a default that is merely well-intentioned.
@description('Default container image tag. Used for API and portal unless overridden.')
param imageTag string = 'latest'

@description('Optional override for the API image tag. Empty = use imageTag.')
param apiImageTag string = ''

@description('Optional override for the portal image tag. Portal repo has its own commit history so this lets you pin to a real portal SHA independently. Empty = use imageTag.')
param portalImageTag string = ''

@description('PostgreSQL admin login.')
param postgresAdminUser string = 'cloudgrange'

@secure()
param postgresAdminPassword string

// ---- SKU + sizing (ADR-048 parameter surface) ----
// AB#9171 (E9): General Purpose, not Burstable. This is a correctness constraint, not a
// sizing preference. Before every in-app Platform update the API takes an ON-DEMAND backup of
// this server, and refuses the update if it cannot — and Azure does not support on-demand
// backup on the Burstable compute tier at all
// (learn.microsoft.com/azure/postgresql/backup-restore/concepts-backup-restore#on-demand-backups).
// A Burstable server therefore produces a delivery path whose in-app updates can never run.
// Standard_D2ds_v4 is the smallest General Purpose SKU. Burstable remains selectable for a
// deployment that knowingly gives up in-app updates.
// Note also Azure's limit of seven on-demand backups per server: an admin deletes older ones.
param postgresSkuName string = 'Standard_D2ds_v4'
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param postgresSkuTier string = 'GeneralPurpose'
@minValue(32)
param postgresStorageGB int = 32
param postgresVersion string = '16'
@minValue(7)
@maxValue(35)
param postgresBackupRetentionDays int = 7
@allowed([ 'Disabled', 'SameZone', 'ZoneRedundant' ])
param postgresHighAvailabilityMode string = 'Disabled'

// AB#1599 — geo-redundant backup parameter (MEDIUM reliability finding)
// Recommended: Disabled for dev/test, Enabled for prod.
@description('PostgreSQL geo-redundant backup. Enable for prod workloads (requires paired region).')
@allowed([ 'Enabled', 'Disabled' ])
param postgresGeoRedundantBackup string = 'Disabled'

// AB#1599 — public network access parameter (HIGH security finding)
// Disabled requires Phase V VNet + private endpoint integration.
// Keep Enabled for Phase IV dev until private endpoint is implemented (ADR-043 Phase V scope).
@description('PostgreSQL public network access. Disabled requires private endpoint (Phase V).')
@allowed([ 'Enabled', 'Disabled' ])
param postgresPublicNetworkAccess string = 'Enabled'

@allowed([ 'standard', 'premium' ])
param keyVaultSku string = 'standard'
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 7

param logAnalyticsSku string = 'PerGB2018'
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

// AB#1599 — LAW daily data cap (HIGH cost finding)
// 0 = unlimited (not recommended for non-prod). Recommended: dev=1, stage=5, prod=-1 (unlimited + alert).
@description('Log Analytics daily data cap in GB. 0 = unlimited (not recommended for non-prod).')
@minValue(0)
param logAnalyticsDailyCapGB int = 1

param apiAppCpu string = '0.5'
param apiAppMemory string = '1Gi'
// AB#9171 (E9): the default is 1, not 0. Scale-to-zero is wrong for this product in every
// environment, not just production: the API hosts the SignalR hub the portal's Platform
// Health card stays connected to, and the built-in relay holds a long-lived connection to it.
// A scaled-to-zero API drops both, and the first request of the day waits behind a cold start.
@minValue(0)
param apiAppMinReplicas int = 1
@minValue(1)
param apiAppMaxReplicas int = 3
param apiAppTargetPort int = 8080

// AB#1599 — HTTP concurrent request scale thresholds (HIGH performance finding)
@description('API ACA scale-out threshold: concurrent HTTP requests per replica before adding a replica.')
param apiAppScaleThreshold int = 100

// AB#1669 — active revisions mode (LOW reliability finding)
// Multiple enables weighted traffic split for zero-downtime deploys.
// When Multiple is set, a default 100%-weight latest rule is added so behavior is equivalent to Single.
@description('ACA active revisions mode. Multiple enables weighted traffic split for zero-downtime deploys.')
@allowed([ 'Single', 'Multiple' ])
param apiAppRevisionsMode string = 'Single'

param portalAppCpu string = '0.25'
param portalAppMemory string = '0.5Gi'
@minValue(0)
param portalAppMinReplicas int = 1
@minValue(1)
param portalAppMaxReplicas int = 2
// AB#9171 (E9): 8080, not 80. The portal image runs nginx as a NON-ROOT user, which cannot
// bind a privileged port, so its server block listens on 8080 (portal docker/nginx.conf).
// The template still said 80, so every readiness probe failed, the revision was marked
// Unhealthy and the portal answered nothing at all. Found by deploying for real — a what-if
// pass cannot see inside the image.
param portalAppTargetPort int = 8080

@description('Portal ACA scale-out threshold: concurrent HTTP requests per replica.')
param portalAppScaleThreshold int = 50

@description('Entra tenant ID — empty = ADR-047 first-run wizard.')
param entraTenantId string = ''

@description('Entra client ID — empty = first-run wizard.')
param entraClientId string = ''

@secure()
param entraClientSecret string = ''

// AB#2379 — authority base URL is now a parameter so operators targeting sovereign clouds
// (Azure Government, Azure China, etc.) can override the default public cloud endpoint.
// Default: https://login.microsoftonline.com  (Azure Public Cloud)
// GovCloud: https://login.microsoftonline.us
// China:    https://login.partner.microsoftonline.cn
@description('Entra authority base URL. Override for sovereign clouds (GovCloud, China). Default = https://login.microsoftonline.com.')
param entraAuthorityBase string = 'https://login.microsoftonline.com'

@description('GHCR username. Empty = images public (ADR-046).')
param ghcrUsername string = ''

@secure()
param ghcrToken string = ''

// H1 security remediation — master key for AES-256 envelope encryption.
// Passed as @secure() so the value is never written to ARM deployment logs.
// Stored in Key Vault (secret name: cloudgrange-master-key) and referenced
// by ACA via keyVaultUrl — never exposed as a plaintext environment variable.
@secure()
@description('256-bit AES master key (base64-encoded). Written to KV at deploy time; referenced by ACA via KV secret reference. Generated externally and passed via environment or @secure() parameter.')
param masterKey string

// AB#1600 — PgBouncer sidecar for connection pooling (MEDIUM performance finding)
@description('Enable PgBouncer connection pooling sidecar on the API container app.')
param enablePgBouncer bool = true

// AB#1668 — Azure Monitor alert rules (MEDIUM opex finding)
@description('Enable Azure Monitor metric alert rules for ACA availability, PG CPU/storage, KV throttling.')
param enableAlertRules bool = true

// Per-resource overrides (ADR-048)
param logAnalyticsName string = ''
param logAnalyticsTags object = {}
param azureMonitorWorkspaceName string = ''
param azureMonitorWorkspaceTags object = {}
param applicationInsightsName string = ''
param applicationInsightsTags object = {}
param managedIdentityName string = ''
param managedIdentityTags object = {}
param keyVaultName string = ''
param keyVaultTags object = {}
param postgresServerName string = ''
param postgresServerTags object = {}
param postgresDatabaseName string = 'cloudgrange'
param containerAppsEnvironmentName string = ''
param containerAppsEnvironmentTags object = {}
param apiAppName string = ''
param apiAppTags object = {}
param portalAppName string = ''
param portalAppTags object = {}

// Optional custom domain for the portal ACA app (AB#1606).
// When set, ACA binds the domain and provisions a managed TLS certificate.
// Operator must have a DNS CNAME record pointing to the ACA default FQDN before deployment.
// Format: plain hostname, e.g. "app.contoso.com" (no scheme, no trailing slash).
@description('Optional custom domain for the portal. Empty = use default *.azurecontainerapps.io HTTPS.')
param portalCustomDomain string = ''

@description('Optional custom domain for the API. Empty = use default *.azurecontainerapps.io HTTPS.')
param apiCustomDomain string = ''

// =============================================================================
// AB#9171 (E9) — Azure Container Apps as a REAL CloudGrange delivery path.
//
// Until now this template deployed two apps (API + portal) and pre-seeded Entra as the
// only identity provider. The product that actually ships on every other path (K3s
// appliance, Windows script, Linux script, BYO Kubernetes, AKS, Azure VM) is the Helm
// chart's seven-component stack, whose identity tier is Keycloak with the `cloudgrange`
// realm, and whose built-in relay is what makes cluster registration and job dispatch
// work at all. An ACA deployment without those is not the same product, so first-run
// setup, SSO, `cg auth login` and cluster registration could never have worked here.
//
// The three additions below close that: a Keycloak Container App (internal ingress; the
// portal proxies /realms/cloudgrange and the Keycloak theme assets to it, exactly as
// the chart's Traefik Ingress does, so auth lives on ONE origin on every path), a relay
// Container App, and Azure Files persistence for the two directories that must survive a
// revision roll (the API's data-protection keys and the relay's enrolment identity).
//
// Foundation updates deliberately do NOT apply here: Azure owns the host and the
// Kubernetes-equivalent layer, so CLOUDGRANGE_FOUNDATION_MANAGED is false and the portal
// renders no Foundation card (pmo/decisions-2026-09-18/update-architecture.md).
// =============================================================================

@description('Keycloak container image. Must match the tag the Helm chart pins (charts/cloudgrange/charts/keycloak/values.yaml) so the realm import and theme paths line up.')
param keycloakImage string = 'quay.io/keycloak/keycloak:26.6.4'

@description('Realm definition imported into Keycloak on first start. Defaults to the same file the Helm chart ships, so ACA and Kubernetes get an identical realm.')
param keycloakRealmJson string = loadTextContent('../charts/cloudgrange/charts/keycloak/files/cloudgrange-realm.json')

@description('Keycloak container app CPU (cores).')
param keycloakAppCpu string = '0.5'

@description('Keycloak container app memory.')
param keycloakAppMemory string = '1Gi'

@description('Optional override for the relay image tag. Empty = use imageTag.')
param relayImageTag string = ''

@description('Relay container app CPU (cores).')
param relayAppCpu string = '0.25'

@description('Relay container app memory.')
param relayAppMemory string = '0.5Gi'

@description('Port the built-in relay listens on for agent connections.')
param relayPort int = 8443

@description('Override the relay container app name. Empty = CAF pattern.')
param relayAppName string = ''

@description('Additional tags for the relay container app.')
param relayAppTags object = {}

@description('Override the Keycloak container app name. Empty = CAF pattern.')
param keycloakAppName string = ''

@description('Additional tags for the Keycloak container app.')
param keycloakAppTags object = {}

@description('Override the storage account name backing the Azure Files shares. Empty = derived, globally unique.')
param storageAccountName string = ''

@description('Platform release this deployment installs. Reported by the API and compared against the update channel. Empty = the effective image tag.')
param platformVersion string = ''

@description('Update channel the in-app Platform updater reads. Must be https; the manifest is trusted by its SHA-256 (there is no signing key — see pmo/decisions-2026-09-18).')
param updateChannelUrl string = 'https://pub-ab113af532ff44ef827c176e42118f17.r2.dev/channels/preview.json'

@description('Static module catalog index the portal lists modules from.')
param moduleCatalogUrl string = 'https://pub-ab113af532ff44ef827c176e42118f17.r2.dev/modules/catalog.json'

@description('ARM api-version used for the pre-update on-demand PostgreSQL backup. The backups sub-resource rejects a write on older versions with 405; this is the version the Azure CLI itself uses.')
param postgresBackupApiVersion string = '2026-01-01-preview'

// -----------------------------------------------------------------------------
// Bootstrap secrets. The platform provisions these — an operator never types one.
// scripts/Install-CloudGrange-Aca.sh generates each on first install, stores it in
// Key Vault and reads it back on every later run, so a redeploy is idempotent and
// does not rotate a password out from under a running database or realm.
// -----------------------------------------------------------------------------

@secure()
@description('Keycloak bootstrap admin username. Generated by the installer; never operator-entered.')
param keycloakAdminUser string

@secure()
@description('Keycloak bootstrap admin password. Generated by the installer; never operator-entered.')
param keycloakAdminPassword string

@secure()
@description('Client secret for the cloudgrange-api confidential client in the realm. Generated by the installer.')
param keycloakApiClientSecret string

@secure()
@description('Bootstrap enrolment token shared by the API and the built-in relay. Generated by the installer.')
param relayEnrollmentToken string

@secure()
@description('First-run password for the realm-admin account the setup wizard provisions. Generated by the installer.')
param realmAdminPassword string

param bringYourOwn object = {
  logAnalyticsWorkspaceId: ''
  applicationInsightsId: ''
  managedIdentityId: ''
  keyVaultId: ''
  containerAppsEnvironmentId: ''
}

// =============================================================================
// CAF naming helper — type-abbr pattern with length handling
// =============================================================================
// CAF resource-type abbreviation table (https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
// Subset for the Phase IV deployed types.
var typeAbbr = {
  resourceGroup: 'rg'
  logAnalyticsWorkspace: 'log'
  applicationInsights: 'appi'
  userAssignedManagedIdentity: 'id'
  keyVault: 'kv'
  postgresqlFlexibleServer: 'psql'
  containerAppsEnvironment: 'cae'
  containerApp: 'ca'
  azureMonitorWorkspace: 'amw'
  dataCollectionEndpoint: 'dce'
  dataCollectionRule: 'dcr'
}

// 6-char deterministic hash from the resource group ID — used to keep
// globally-unique resources globally-unique without leaking customer identity.
var rgHash = substring(uniqueString(resourceGroup().id), 0, 6)

// Length-constrained types (Key Vault = 24 chars max) need a shorter workload token.
// Budget for KV: 24 - typeAbbr(2) - env(max 5='stage') - regionCode(max 4='wus2') - instance(3) - hash(6) = 4
// Truncate workload to 6 chars to leave headroom; examples with workload='cloudgrange':
//   env=dev region=cus instance=001 hash=abc123 → kvcloudsdevcus001abc123 (23 chars)
//   env=stage region=eus2 instance=001 hash=abc123 → kvcloudsstageeus2001abc123 → would still overflow with the full 6+5+4+3+6=24, so use 4-char truncate to be safe
var workloadShort = length(workload) > 4 ? substring(workload, 0, 4) : workload

// Build the CAF pattern name. Container apps add a role discriminator since
// multiple apps share workload+env+region+instance scope.
func cafName(typeAbbrValue string, workloadValue string, envValue string, regionValue string, instanceValue string) string =>
  '${typeAbbrValue}-${workloadValue}-${envValue}-${regionValue}-${instanceValue}'

func cafNameWithRole(typeAbbrValue string, workloadValue string, roleValue string, envValue string, regionValue string, instanceValue string) string =>
  '${typeAbbrValue}-${workloadValue}-${roleValue}-${envValue}-${regionValue}-${instanceValue}'

// AB#9171 (E9) — a Container App name must END in an alphanumeric character. Clamping a CAF name
// to the 32-char limit can cut it on a hyphen, and whether it does depends on how long the region
// code is, so the identical template deploys in one region and is refused in another. Drop up to
// two trailing hyphens after a clamp. A name that already fits is returned unchanged, so this
// never renames an app in an existing deployment.
func trimTrailingHyphens(value string) string =>
  endsWith(value, '-')
    ? (endsWith(substring(value, 0, length(value) - 1), '-')
        ? substring(value, 0, length(value) - 2)
        : substring(value, 0, length(value) - 1))
    : value

// Length-constrained pattern for Key Vault (24 chars max, alphanumeric+hyphen).
// Drop hyphens and append the 6-char hash for global uniqueness.
func cafNameLengthConstrained(typeAbbrValue string, workloadValue string, envValue string, regionValue string, instanceValue string, hashValue string) string =>
  '${typeAbbrValue}${workloadValue}${envValue}${regionValue}${instanceValue}${hashValue}'

// Effective names — override wins, otherwise derive from the pattern.
var logAnalyticsNameEffective = empty(logAnalyticsName) ? cafName(typeAbbr.logAnalyticsWorkspace, workload, environment, regionCode, instance) : logAnalyticsName
var azureMonitorWorkspaceNameEffective = empty(azureMonitorWorkspaceName) ? cafName(typeAbbr.azureMonitorWorkspace, workload, environment, regionCode, instance) : azureMonitorWorkspaceName
var applicationInsightsNameEffective = empty(applicationInsightsName) ? cafName(typeAbbr.applicationInsights, workload, environment, regionCode, instance) : applicationInsightsName
var managedIdentityNameEffective = empty(managedIdentityName) ? cafName(typeAbbr.userAssignedManagedIdentity, workload, environment, regionCode, instance) : managedIdentityName
var keyVaultNameEffective = empty(keyVaultName) ? cafNameLengthConstrained(typeAbbr.keyVault, workloadShort, environment, regionCode, instance, rgHash) : keyVaultName
var postgresServerNameEffective = empty(postgresServerName) ? cafName(typeAbbr.postgresqlFlexibleServer, workload, environment, regionCode, instance) : postgresServerName
var containerAppsEnvironmentNameEffective = empty(containerAppsEnvironmentName) ? cafName(typeAbbr.containerAppsEnvironment, workload, environment, regionCode, instance) : containerAppsEnvironmentName
var apiAppNameEffective = empty(apiAppName) ? cafNameWithRole(typeAbbr.containerApp, workload, 'api', environment, regionCode, instance) : apiAppName
// AB#1669 — ACA name limit is 32 chars. 'portal' role makes the name 33 chars for common
// workload='cloudgrange' deployments. Clamp to 32 by substring. API uses 'api' (3 chars) and
// fits in 30; portal uses 'portal' (6 chars) and would be 33 — trim to 32.
// AB#9171 (E9) — clamping to 32 is not enough on its own: a Container App name must also END in
// an alphanumeric. Whether the 32nd character happens to be a hyphen depends on the region code's
// length, so the same template deploys in one region and is refused in another. With
// workload='cloudgrange' the portal name is 34 in eastus (regionCode 'eus') and clamps to
// '…-prod-eus-0', which Azure accepts, but 35 in westus3 ('wus3') and clamps to '…-test-wus3-',
// which fails the whole deployment with ContainerAppInvalidName after everything else is built.
// _trimTrailingHyphens drops up to two trailing hyphens after the clamp. Names that already fit
// are untouched, so this does not rename anything in an existing deployment.
var _portalAppNameRaw = cafNameWithRole(typeAbbr.containerApp, workload, 'portal', environment, regionCode, instance)
var _portalAppName32 = length(_portalAppNameRaw) > 32 ? substring(_portalAppNameRaw, 0, 32) : _portalAppNameRaw
var portalAppNameEffective = empty(portalAppName) ? trimTrailingHyphens(_portalAppName32) : portalAppName

// AB#9171 (E9) — same 32-char Container App clamp for the two new apps. 'keycloak' (8) and
// 'relay' (5) both overflow for workload='cloudgrange', so both go through the same trim the
// portal already needed. A what-if pass does NOT catch an over-length Container App name: the
// provider only validates it on create (ContainerAppInvalidName), which is why this is clamped
// here rather than left to be discovered on the real deploy.
var _keycloakAppNameRaw = cafNameWithRole(typeAbbr.containerApp, workload, 'kc', environment, regionCode, instance)
var _keycloakAppName32 = length(_keycloakAppNameRaw) > 32 ? substring(_keycloakAppNameRaw, 0, 32) : _keycloakAppNameRaw
var keycloakAppNameEffective = empty(keycloakAppName) ? trimTrailingHyphens(_keycloakAppName32) : keycloakAppName
var _relayAppNameRaw = cafNameWithRole(typeAbbr.containerApp, workload, 'relay', environment, regionCode, instance)
var _relayAppName32 = length(_relayAppNameRaw) > 32 ? substring(_relayAppNameRaw, 0, 32) : _relayAppNameRaw
var relayAppNameEffective = empty(relayAppName) ? trimTrailingHyphens(_relayAppName32) : relayAppName
// Storage account names are 3-24 chars, lowercase alphanumeric only, and globally unique.
var _storageNameRaw = toLower('st${workloadShort}${environment}${regionCode}${instance}${rgHash}')
var storageAccountNameEffective = empty(storageAccountName) ? (length(_storageNameRaw) > 24 ? substring(_storageNameRaw, 0, 24) : _storageNameRaw) : storageAccountName

// Tag composition helper — every resource gets commonTags + autoTags + own.
// Length-constrained types also get a DisplayName tag with the readable CAF form.
var allTagsBase = union(commonTags, autoTags)
var keyVaultDisplayName = cafName(typeAbbr.keyVault, workload, environment, regionCode, instance)
var kvDisplayTag = { DisplayName: keyVaultDisplayName }

// =============================================================================
// Image / connection-string composition
// =============================================================================
var imagesArePrivate = !empty(ghcrToken)
var _apiImageTagEff    = empty(apiImageTag)    ? imageTag : apiImageTag
var _portalImageTagEff = empty(portalImageTag) ? imageTag : portalImageTag
var apiImage    = 'ghcr.io/cloudgrange/cloudgrange-api:${_apiImageTagEff}'
var portalImage = 'ghcr.io/cloudgrange/cloudgrange-portal:${_portalImageTagEff}'
// AB#9171 (E9)
var _relayImageTagEff = empty(relayImageTag) ? imageTag : relayImageTag
var relayImage = 'ghcr.io/cloudgrange/cloudgrange-relay:${_relayImageTagEff}'
var platformVersionEffective = empty(platformVersion) ? imageTag : platformVersion
var pgFqdn = '${postgresServerNameEffective}.postgres.database.azure.com'
var oidcPreseed = !empty(entraClientId)
// AB#2379 — use entraAuthorityBase parameter instead of hardcoded public cloud URL.
// Trailing slash is stripped from the base before appending tenant path, so both
// 'https://login.microsoftonline.com' and 'https://login.microsoftonline.com/' work.
var _entraAuthorityBase = endsWith(entraAuthorityBase, '/') ? substring(entraAuthorityBase, 0, length(entraAuthorityBase) - 1) : entraAuthorityBase
var entraAuthority = empty(entraTenantId) ? '' : '${_entraAuthorityBase}/${entraTenantId}/v2.0'
var oidcApiEnv = oidcPreseed ? [
  { name: 'Keycloak__Authority', value: entraAuthority }
  { name: 'Keycloak__ClientId', value: entraClientId }
  { name: 'Keycloak__ClientSecret', secretRef: 'entra-client-secret' }
  { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
] : []

// AB#9171 (E9) — the DEFAULT identity provider on this path is the platform's own Keycloak,
// the same as on every other delivery path. Entra pre-seed (oidcApiEnv above) remains an
// opt-in override for operators who supply entraClientId. The authority is the PUBLIC one,
// through the portal origin, because that is the issuer Keycloak mints tokens for once
// KC_HOSTNAME points at the portal — validating against the internal address would reject
// every token the browser and the CLI present.
var keycloakApiEnv = [
  { name: 'Keycloak__Authority', value: keycloakPublicAuthority }
  { name: 'Keycloak__ClientId', value: 'cloudgrange-api' }
  { name: 'Keycloak__ClientSecret', secretRef: 'kc-api-client-secret' }
  { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
]

// AB#1600 — PgBouncer host: when enabled, API connects to localhost (sidecar), else PG FQDN directly.
var dbHost = enablePgBouncer ? 'localhost' : pgFqdn

// AB#1600 — KV secret name for the PG password (written to KV at provision time).
// Referenced from ACA via keyVaultUrl pattern — never passed as a plaintext env var.
var pgPasswordSecretName = 'cs-${environment}-core-db-password'

// H1 security remediation — KV secret name for the AES-256 master key.
var masterKeySecretName = 'cloudgrange-master-key'

// AB#9171 (E9) — the platform's own bootstrap secrets. Same rule as the master key: written to
// Key Vault at deploy time and referenced by the Container Apps via keyVaultUrl, never as a
// plaintext env var, and never typed by an operator.
var keycloakAdminUserSecretName     = 'cloudgrange-keycloak-admin-user'
var keycloakAdminPasswordSecretName = 'cloudgrange-keycloak-admin-password'
var keycloakApiClientSecretName     = 'cloudgrange-keycloak-api-client-secret'
var relayEnrollmentTokenSecretName  = 'cloudgrange-relay-enrollment-token'
var realmAdminPasswordSecretName    = 'cloudgrange-realm-admin-password'

// AB#2374 — KV secret name for the Entra/AAD OIDC client secret.
// Stored in KV at deploy time; ACA references via keyVaultUrl — never as plaintext env var.
var entraClientSecretName = 'cloudgrange-entra-client-secret'

// AB#2375 — KV secret name for the Application Insights connection string.
// Connection strings contain the instrumentation key and are treated as sensitive.
// Stored in KV at deploy time; ACA references via keyVaultUrl — never as plaintext env var.
var appInsightsSecretName = 'cloudgrange-appinsights-connection-string'

// KV DNS suffix — use az.environment() to ensure compatibility across sovereign clouds (no-hardcoded-env-urls)
var kvDnsSuffix = az.environment().suffixes.keyvaultDns

// =============================================================================
// Bring-your-own resource ID parsing
// =============================================================================
// Full ARM resource IDs look like:
//   /subscriptions/<subId>/resourceGroups/<rg>/providers/<ns>/<type>/<name>
// Indices:                  0/1            /2 /3            /4  /5        /6/7    /8
// When the BYO ID is empty we substitute a dummy ID of the right shape so the
// split() always returns a 9-element string[] — required because Bicep type-checks
// indexing operations and rejects "<empty array> | string[]". The dummy resource is
// never actually referenced — the corresponding `existing` declarations are gated
// by `if (!empty(byoXxxId))`.
var byoLawId = bringYourOwn.?logAnalyticsWorkspaceId ?? ''
var byoAppiId = bringYourOwn.?applicationInsightsId ?? ''
var byoMiId = bringYourOwn.?managedIdentityId ?? ''
var byoKvId = bringYourOwn.?keyVaultId ?? ''
var byoCaeId = bringYourOwn.?containerAppsEnvironmentId ?? ''

var dummyId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/_dummy/providers/_/_/_'

var byoLawParts = split(empty(byoLawId) ? dummyId : byoLawId, '/')
var byoAppiParts = split(empty(byoAppiId) ? dummyId : byoAppiId, '/')
var byoMiParts = split(empty(byoMiId) ? dummyId : byoMiId, '/')
var byoKvParts = split(empty(byoKvId) ? dummyId : byoKvId, '/')
var byoCaeParts = split(empty(byoCaeId) ? dummyId : byoCaeId, '/')

// =============================================================================
// Observability — Log Analytics + Application Insights
// =============================================================================

resource newLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(byoLawId)) {
  name: logAnalyticsNameEffective
  location: location
  tags: union(allTagsBase, logAnalyticsTags)
  properties: {
    sku: { name: logAnalyticsSku }
    retentionInDays: logAnalyticsRetentionDays
    // AB#1599 — daily data cap to prevent unbounded cost (HIGH cost finding)
    workspaceCapping: {
      dailyQuotaGb: logAnalyticsDailyCapGB == 0 ? -1 : logAnalyticsDailyCapGB
    }
  }
}

resource existingLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (!empty(byoLawId)) {
  name: byoLawParts[8]
  scope: resourceGroup(byoLawParts[2], byoLawParts[4])
}

var lawId = empty(byoLawId) ? newLaw.id : existingLaw.id
var lawCustomerId = empty(byoLawId) ? newLaw.properties.customerId : existingLaw.properties.customerId
var lawSharedKey = empty(byoLawId) ? newLaw.listKeys().primarySharedKey : existingLaw.listKeys().primarySharedKey

resource newAppi 'Microsoft.Insights/components@2020-02-02' = if (empty(byoAppiId)) {
  name: applicationInsightsNameEffective
  location: location
  tags: union(allTagsBase, applicationInsightsTags)
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: lawId
  }
}

resource existingAppi 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(byoAppiId)) {
  name: byoAppiParts[8]
  scope: resourceGroup(byoAppiParts[2], byoAppiParts[4])
}

var appiConnectionString = empty(byoAppiId) ? newAppi.properties.ConnectionString : existingAppi.properties.ConnectionString

// =============================================================================
// Observability — Azure Monitor Workspace + DCE + DCR (metrics / Prometheus)
// ADR-016 (amendment 1, AB#1927): AMW is the PaaS metrics backend.
// LAW is logs only. All metrics MUST flow via remote_write → AMW.
// AB#1928: provisions this stack.
// =============================================================================

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: azureMonitorWorkspaceNameEffective
  location: location
  tags: union(allTagsBase, azureMonitorWorkspaceTags)
}

// DCE provides the metricsIngestion.endpoint URL for Prometheus remote_write.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: cafName(typeAbbr.dataCollectionEndpoint, workload, environment, regionCode, instance)
  location: location
  tags: allTagsBase
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

// DCR routes Microsoft-PrometheusMetrics from the DCE ingestion endpoint to the AMW.
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: cafName(typeAbbr.dataCollectionRule, workload, environment, regionCode, instance)
  location: location
  tags: allTagsBase
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: [ 'Microsoft-PrometheusMetrics' ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'cloudgrangeAmw'
          accountResourceId: amw.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-PrometheusMetrics' ]
        destinations: [ 'cloudgrangeAmw' ]
      }
    ]
  }
}

// Monitoring Metrics Publisher on the DCR — allows the managed identity to push
// Prometheus remote_write samples to AMW via this DCR ingestion endpoint.
// AB#1668 — correct built-in Monitoring Metrics Publisher role GUID.
// The old GUID (11e9 variant) does not exist in all tenants; 4e42 variant is canonical.
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
resource dcrPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, miId, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

var amwId = amw.id
var amwQueryEndpoint = amw.properties.metrics.prometheusQueryEndpoint
var dceMetricsIngestionEndpoint = dce.properties.metricsIngestion.endpoint
var dcrImmutableId = dcr.properties.immutableId

// =============================================================================
// Identity — User-Assigned Managed Identity
// =============================================================================

resource newMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (empty(byoMiId)) {
  name: managedIdentityNameEffective
  location: location
  tags: union(allTagsBase, managedIdentityTags)
}

resource existingMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(byoMiId)) {
  name: byoMiParts[8]
  scope: resourceGroup(byoMiParts[2], byoMiParts[4])
}

var miId = empty(byoMiId) ? newMi.id : existingMi.id
var miPrincipalId = empty(byoMiId) ? newMi.properties.principalId : existingMi.properties.principalId
var miClientId = empty(byoMiId) ? newMi.properties.clientId : existingMi.properties.clientId
var miNameForPg = empty(byoMiId) ? newMi.name : existingMi.name

// =============================================================================
// Key Vault
// AB#1599 — enablePurgeProtection: true (HIGH security finding)
// AB#1600 — PG password written as KV secret; ACA references via keyVaultUrl
// AB#1668 — KV diagnostic settings → LAW (MEDIUM security finding)
// =============================================================================

resource newKv 'Microsoft.KeyVault/vaults@2023-07-01' = if (empty(byoKvId)) {
  name: keyVaultNameEffective
  location: location
  tags: union(allTagsBase, keyVaultTags, kvDisplayTag)
  properties: {
    sku: { family: 'A', name: keyVaultSku }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionDays
    // AB#1599 — purge protection: once set cannot be unset; required by secrets-handling design.
    // Note: the dev KV (rg-cloudgrange-dev-cus-001) must be re-created or purge protection applied
    // manually before the next deploy if upgrading from a pre-Wave-3 state.
    enablePurgeProtection: true
  }
}

resource existingKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(byoKvId)) {
  name: byoKvParts[8]
  scope: resourceGroup(byoKvParts[2], byoKvParts[4])
}

// AB#2349 / ADR-047 amendment: managed identity needs Secrets Officer (not just User)
// so the API can write the initial admin token to KV at first start. Secrets Officer
// grants Get + List + Set + Delete; User is read-only.
// Role IDs from https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
//   Key Vault Secrets User    : 4633458b-17de-408a-b874-0445c86b69e6 (read)
//   Key Vault Secrets Officer : b86a8fe4-44ce-4948-aee5-eccb2c155cd7 (read+write+delete)
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
resource kvRoleAssignNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(byoKvId)) {
  name: guid(newKv.id, miId, kvSecretsOfficerRoleId)
  scope: newKv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}
// When BYO KV is used the role assignment is the customer's responsibility — we
// do not modify access on existing shared resources.

// AB#1600 — Write PG admin password to Key Vault as a secret.
// ACA container apps reference this secret via keyVaultUrl rather than a plaintext value.
// The @secure() parameter ensures the password is never written to ARM deployment logs.
resource pgPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: pgPasswordSecretName
  properties: {
    value: postgresAdminPassword
    attributes: { enabled: true }
  }
}

// H1 security remediation — Write the AES-256 master key to Key Vault at deploy time.
// The @secure() parameter ensures the raw key is never written to ARM deployment logs.
// ACA references this secret via keyVaultUrl (see apiApp secrets block) — the plaintext
// key is never visible in az containerapp show, ARM exports, or the Azure portal.
resource masterKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: masterKeySecretName
  properties: {
    value: masterKey
    attributes: { enabled: true }
  }
}

// AB#9171 (E9) — the platform's own bootstrap secrets, written to Key Vault at deploy time and
// consumed by the Container Apps through keyVaultUrl references. On Kubernetes the equivalent
// values are generated in-cluster by templates/secrets-bootstrap-job.yaml and never overwritten
// by an upgrade; here scripts/Install-CloudGrange-Aca.sh plays that role, reading each value back
// out of this vault on a redeploy so the same guarantee holds.
resource keycloakAdminUserSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: keycloakAdminUserSecretName
  properties: { value: keycloakAdminUser, attributes: { enabled: true } }
}

resource keycloakAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: keycloakAdminPasswordSecretName
  properties: { value: keycloakAdminPassword, attributes: { enabled: true } }
}

resource keycloakApiClientSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: keycloakApiClientSecretName
  properties: { value: keycloakApiClientSecret, attributes: { enabled: true } }
}

resource relayEnrollmentTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: relayEnrollmentTokenSecretName
  properties: { value: relayEnrollmentToken, attributes: { enabled: true } }
}

resource realmAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: realmAdminPasswordSecretName
  properties: { value: realmAdminPassword, attributes: { enabled: true } }
}

// AB#2374 — Write the Entra/AAD OIDC client secret to Key Vault at deploy time.
// Only written when OIDC pre-seed is active (entraClientId non-empty).
// ACA references this secret via keyVaultUrl — never as a plaintext env-var value.
// The @secure() parameter on entraClientSecret prevents the value appearing in ARM logs.
resource entraClientSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId) && oidcPreseed) {
  parent: newKv
  name: entraClientSecretName
  properties: {
    value: entraClientSecret
    attributes: { enabled: true }
  }
}

// AB#2375 — Write the Application Insights connection string to Key Vault at deploy time.
// Connection strings contain the instrumentation key and are treated as sensitive.
// ACA references this secret via keyVaultUrl — never as a plaintext env-var value.
resource appInsightsSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: appInsightsSecretName
  properties: {
    value: appiConnectionString
    attributes: { enabled: true }
  }
}

// AB#1668 — KV diagnostic settings → LAW (MEDIUM security finding)
// Logs all AuditEvent (secret get/set/delete) to Log Analytics for 90-day retention.
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (empty(byoKvId)) {
  name: 'kv-diag'
  scope: newKv
  properties: {
    workspaceId: lawId
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        // retentionPolicy is deprecated in diagnostic settings API 2021-05-01-preview+.
        // Retention is now controlled by the Log Analytics workspace retention setting.
      }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// Effective KV reference values used in ACA secret block
var kvNameEffective = empty(byoKvId) ? newKv.name : existingKv.name
// AB#1600 — KV secret URI for the PG password ACA secret reference
var pgPasswordSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${pgPasswordSecretName}'
// H1 — KV secret URI for the AES-256 master key ACA secret reference
var masterKeySecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${masterKeySecretName}'
// AB#2374 — KV secret URI for the Entra OIDC client secret ACA secret reference
var entraClientSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${entraClientSecretName}'
// AB#2375 — KV secret URI for the App Insights connection string ACA secret reference
var appInsightsSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${appInsightsSecretName}'
// AB#9171 (E9)
var keycloakAdminUserSecretUri     = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${keycloakAdminUserSecretName}'
var keycloakAdminPasswordSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${keycloakAdminPasswordSecretName}'
var keycloakApiClientSecretUri     = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${keycloakApiClientSecretName}'
var relayEnrollmentTokenSecretUri  = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${relayEnrollmentTokenSecretName}'

// =============================================================================
// PostgreSQL Flexible Server (always created — workload-specific)
// AB#1599 — postgresGeoRedundantBackup and postgresPublicNetworkAccess parameters
// AB#1668 — PG diagnostic settings → LAW
// =============================================================================

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: postgresServerNameEffective
  location: location
  tags: union(allTagsBase, postgresServerTags)
  sku: { name: postgresSkuName, tier: postgresSkuTier }
  properties: {
    version: postgresVersion
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: postgresStorageGB }
    backup: {
      backupRetentionDays: postgresBackupRetentionDays
      // AB#1599 — geo-redundant backup parameter (MEDIUM reliability finding)
      // Recommended: Disabled for dev, Enabled for prod.
      geoRedundantBackup: postgresGeoRedundantBackup
    }
    highAvailability: {
      // HA mode: ZoneRedundant requires postgresSkuTier=GeneralPurpose or MemoryOptimized.
      // Incompatible with Burstable — do not set ZoneRedundant when using Standard_B1ms.
      mode: postgresHighAvailabilityMode
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
    // AB#1599 — public network access parameter (HIGH security finding)
    // Disabled requires Phase V private endpoint. Keep Enabled for Phase IV dev.
    network: {
      publicNetworkAccess: postgresPublicNetworkAccess
    }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: pg
  name: postgresDatabaseName
}

resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = if (postgresPublicNetworkAccess == 'Enabled') {
  parent: pg
  name: 'AllowAllAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

module pgAadAdmin 'pg-aad-admin.bicep' = {
  name: 'pg-aad-admin'
  params: {
    postgresServerName: pg.name
    principalId: miPrincipalId
    principalName: miNameForPg
    tenantId: subscription().tenantId
  }
  dependsOn: [ pgFwAzure, pgDb ]
}

// AB#1668 — PG diagnostic settings removed: PostgreSQL Flexible Server log categories
// (PostgreSQLFlexibleServerQueryStore, PostgreSQLFlexibleServerLogs) are not supported
// in all Azure regions (e.g. Central US returns BadRequest for both categories).
// PG metrics are captured via the ACA environment's built-in Log Analytics integration.
// TODO: Re-enable if/when the region supports it, using allLogs category filter instead.
// resource pgDiagnostics removed

// =============================================================================
// Container Apps Environment
// =============================================================================

resource newCae 'Microsoft.App/managedEnvironments@2024-03-01' = if (empty(byoCaeId)) {
  name: containerAppsEnvironmentNameEffective
  location: location
  tags: union(allTagsBase, containerAppsEnvironmentTags)
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: lawCustomerId
        sharedKey: lawSharedKey
      }
    }
  }
}

resource existingCae 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!empty(byoCaeId)) {
  name: byoCaeParts[8]
  scope: resourceGroup(byoCaeParts[2], byoCaeParts[4])
}

var caeId     = empty(byoCaeId) ? newCae.id : existingCae.id
var caeDomain = empty(byoCaeId) ? newCae.properties.defaultDomain : existingCae.properties.defaultDomain

var registries = imagesArePrivate ? [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-token'
  }
] : []

// =============================================================================
// AB#9171 (E9) — Azure Files persistence for the two directories that MUST survive a
// revision roll.
//
// Container Apps replicas are ephemeral, and an in-app Platform update is a new revision.
// Two directories cannot be ephemeral:
//   - the API's /etc/cloudgrange holds the ASP.NET Core data-protection key ring. On a
//     fresh key ring every existing auth cookie and every encrypted-at-rest value written
//     with the old key becomes unreadable, so an update would silently sign everybody out
//     and break previously stored secrets. The Helm chart gives this a PVC for the same
//     reason (charts/api, api-secrets).
//   - the relay's /var/lib/cloudgrange-relay/identity holds its enrolment identity. Lose
//     it and the built-in relay re-enrols as a brand-new relay after every update, leaving
//     an orphan behind and detaching the site it was bound to.
//
// A BYO Container Apps Environment is not supported for the platform path, because these
// storage definitions are children of the environment.
// =============================================================================

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (empty(byoCaeId)) {
  name: storageAccountNameEffective
  location: location
  tags: allTagsBase
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Azure Files SMB from a Container Apps environment authenticates with the account key.
    allowSharedKeyAccess: true
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = if (empty(byoCaeId)) {
  parent: storage
  name: 'default'
}

resource apiSecretsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (empty(byoCaeId)) {
  parent: fileServices
  name: 'api-secrets'
  properties: { shareQuota: 5 }
}

resource relayIdentityShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (empty(byoCaeId)) {
  parent: fileServices
  name: 'relay-identity'
  properties: { shareQuota: 5 }
}

resource apiSecretsStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = if (empty(byoCaeId)) {
  parent: newCae
  name: 'api-secrets'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: 'api-secrets'
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [ apiSecretsShare ]
}

resource relayIdentityStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = if (empty(byoCaeId)) {
  parent: newCae
  name: 'relay-identity'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: 'relay-identity'
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [ relayIdentityShare ]
}

// -----------------------------------------------------------------------------
// AB#9171 (E9) — deterministic internal FQDNs.
//
// Every app in a Container Apps environment resolves as
// <app>.internal.<environment default domain>, so the whole mesh of URLs (API -> Keycloak,
// portal -> API, portal -> Keycloak, relay -> API) can be computed here in one pass instead
// of needing a second deployment to learn the FQDNs. Public traffic has exactly one origin,
// the portal, which proxies /api, /hubs, /realms/cloudgrange and /resources/<version>.
// -----------------------------------------------------------------------------
var keycloakInternalFqdn = '${keycloakAppNameEffective}.internal.${caeDomain}'
var apiInternalFqdn      = '${apiAppNameEffective}.internal.${caeDomain}'
var portalPublicUrl      = empty(portalCustomDomain) ? 'https://${portalAppNameEffective}.${caeDomain}' : 'https://${portalCustomDomain}'
// Computed rather than read back from apiApp.properties: the API app's own template needs
// this value, and a resource cannot reference itself. An external Container App's FQDN is
// always <app name>.<environment default domain>.
var apiPublicUrl         = empty(apiCustomDomain) ? 'https://${apiAppNameEffective}.${caeDomain}' : 'https://${apiCustomDomain}'
// Browsers and the CLI reach Keycloak through the portal origin, so that is the issuer the
// realm must mint tokens for, and the authority the API must validate against.
var keycloakPublicAuthority = '${portalPublicUrl}/realms/cloudgrange'

// =============================================================================
// API Container App (external ingress on 8080)
// AB#1599 — HTTP scaling rule (HIGH performance finding)
// AB#1600 — KV secret reference for PG password; PgBouncer sidecar
// AB#1667 — health probes (HIGH security/reliability finding)
// =============================================================================

// AB#1600 — PgBouncer sidecar container definition.
// API connects to localhost:5432 (PgBouncer) instead of PG FQDN directly.
// Limits PG connection count: MAX_CLIENT_CONN × replicas, pooled via transaction mode.
// Pin to a specific tag in production; 'latest' only acceptable for dev.
var pgBouncerContainer = {
  name: 'pgbouncer'
  image: 'edoburu/pgbouncer:v1.23.1-p3'
  resources: { cpu: json('0.25'), memory: '0.5Gi' }
  env: [
    { name: 'DB_HOST', value: pgFqdn }
    { name: 'DB_PORT', value: '5432' }
    { name: 'DB_USER', value: postgresAdminUser }
    { name: 'DB_PASSWORD', secretRef: 'pg-password' }
    { name: 'POOL_MODE', value: 'transaction' }
    { name: 'MAX_CLIENT_CONN', value: '200' }
    { name: 'DEFAULT_POOL_SIZE', value: '20' }
    { name: 'AUTH_TYPE', value: 'scram-sha-256' }
  ]
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppNameEffective
  location: location
  tags: union(allTagsBase, apiAppTags)
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${miId}': {} }
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      // AB#1669 — revisionsMode parameter (LOW reliability finding)
      activeRevisionsMode: apiAppRevisionsMode
      ingress: {
        external: true
        targetPort: apiAppTargetPort
        transport: 'auto'
        // AB#1606: bind custom domain + managed TLS certificate when apiCustomDomain is provided.
        // ACA auto-provisions the TLS cert via ACMEv2 after the CNAME record propagates.
        customDomains: empty(apiCustomDomain) ? [] : [
          {
            name: apiCustomDomain
            bindingType: 'SniEnabled'
            certificateId: null
          }
        ]
        // AB#1669 — traffic weights must always sum to 100; set latest revision to 100%.
        // This applies in both Single and Multiple revision modes. In Single mode ACA
        // ignores the traffic block but the ARM validator requires it to be valid.
        traffic: [
          { weight: 100, latestRevision: true }
        ]
      }
      registries: registries
      // AB#1600 — ACA secrets: PG password referenced via KV URI (not plaintext value)
      // H1   — ACA secrets: master key referenced via KV URI (not plaintext value)
      // AB#2374 — ACA secrets: Entra client secret referenced via KV URI (not plaintext value)
      // AB#2375 — ACA secrets: App Insights connection string referenced via KV URI (not plaintext value)
      // The managed identity (miId) must hold Key Vault Secrets Officer role on the KV.
      secrets: concat(
        [
          {
            name: 'pg-password'
            keyVaultUrl: pgPasswordSecretUri
            identity: miId
          }
          // H1 security remediation — master key KV secret reference.
          // Never set as a direct env var value; always resolved via Key Vault.
          {
            name: 'cloudgrange-master-key'
            keyVaultUrl: masterKeySecretUri
            identity: miId
          }
          // AB#2375 — App Insights connection string KV secret reference.
          // Connection strings contain the instrumentation key — treat as sensitive.
          {
            name: 'appinsights-connection-string'
            keyVaultUrl: appInsightsSecretUri
            identity: miId
          }
          // AB#9171 (E9) — the API's own client secret in the realm, and the relay bootstrap token.
          {
            name: 'kc-api-client-secret'
            keyVaultUrl: keycloakApiClientSecretUri
            identity: miId
          }
          {
            name: 'relay-enrollment-token'
            keyVaultUrl: relayEnrollmentTokenSecretUri
            identity: miId
          }
        ],
        // AB#2374 — Entra client secret stored in KV; referenced via keyVaultUrl (not inline value).
        oidcPreseed ? [ { name: 'entra-client-secret', keyVaultUrl: entraClientSecretUri, identity: miId } ] : [],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: concat(
        [
          {
            name: 'cloudgrange-api'
            image: apiImage
            resources: { cpu: json(apiAppCpu), memory: apiAppMemory }
            env: union([
              { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
              // AB#1600 — DB connection string uses pg-password secret ref (not plaintext)
              // When PgBouncer is enabled, dbHost = localhost (sidecar); else PG FQDN.
              { name: 'ConnectionStrings__Default', secretRef: 'pg-password' }
              { name: 'ConnectionStrings__DefaultHost', value: dbHost }
              { name: 'ConnectionStrings__DefaultDatabase', value: postgresDatabaseName }
              { name: 'ConnectionStrings__DefaultUser', value: postgresAdminUser }
              // AB#2375 — App Insights connection string injected via KV secret reference.
              // Connection strings contain the instrumentation key and must not be plaintext.
              { name: 'ApplicationInsights__ConnectionString', secretRef: 'appinsights-connection-string' }
              { name: 'AZURE_CLIENT_ID', value: miClientId }
              { name: 'Monitoring__Endpoints__1__HealthUrl', value: 'https://${portalAppNameEffective}.${caeDomain}' }
              // AMW env vars — used by AzureMonitorBackend (IMetricsBackend, ADR-016).
              // AB#1928: env var names standardised to AZURE_MONITOR_* for cross-language compatibility.
              { name: 'AZURE_MONITOR_WORKSPACE_ENDPOINT', value: amwQueryEndpoint }
              { name: 'AZURE_MONITOR_DCE_ENDPOINT', value: dceMetricsIngestionEndpoint }
              { name: 'AZURE_MONITOR_DCR_IMMUTABLE_ID', value: dcrImmutableId }
              // H1 security remediation — master key injected via KV secret reference.
              // The raw base64 key is NEVER stored as a plaintext env var value.
              { name: 'CLOUDGRANGE_MASTER_KEY', secretRef: 'cloudgrange-master-key' }
              // AB#2349 / ADR-047 amendment — substrate flag + KV name so the bootstrap
              // can write the initial admin token to KV instead of an unreachable file.
              // Operator retrieves with:
              //   az keyvault secret show --vault-name <kv> --name cloudgrange-initial-admin-token --query value -o tsv
              { name: 'CLOUDGRANGE_DEPLOYMENT_MODE', value: 'paas' }
              { name: 'CLOUDGRANGE_KEY_VAULT_NAME',  value: kvNameEffective }
              // AB#2412 — env vars required by PaaSAdapter.TriggerImageUpdateAsync and host-info endpoint.
              // AB#2403 — AZURE_TENANT_ID added so PaaSAdapter DefaultAzureCredential can resolve the tenant.
              // These are resolved from ARM built-in functions at deploy time — no hardcoded values.
              { name: 'AZURE_SUBSCRIPTION_ID',          value: subscription().subscriptionId }
              { name: 'AZURE_TENANT_ID',                value: subscription().tenantId }
              { name: 'CLOUDGRANGE_ACA_RESOURCE_GROUP',  value: resourceGroup().name }
              { name: 'CLOUDGRANGE_ACA_APP_NAME',        value: apiAppNameEffective }
              { name: 'CLOUDGRANGE_AZURE_REGION',        value: location }
              // ---- AB#9171 (E9) -------------------------------------------------------
              // The runtime selector. CLOUDGRANGE_DEPLOYMENT_MODE above stays for
              // compatibility; CLOUDGRANGE_RUNTIME is the name the update architecture uses
              // and is what selects the Container Apps update executor.
              { name: 'CLOUDGRANGE_RUNTIME',             value: 'aca' }
              // Azure owns the host and the orchestration layer here, so there is no
              // CloudGrange Foundation to update and the portal renders no Foundation card.
              { name: 'CLOUDGRANGE_FOUNDATION_MANAGED',  value: 'false' }
              { name: 'CLOUDGRANGE_PLATFORM_VERSION',    value: platformVersionEffective }
              { name: 'CLOUDGRANGE_IMAGE_TAG',           value: _apiImageTagEff }
              { name: 'CLOUDGRANGE_VERSION',             value: _apiImageTagEff }
              { name: 'CLOUDGRANGE_PORTAL_VERSION',      value: _portalImageTagEff }
              { name: 'CLOUDGRANGE_SOLUTION_VERSION',    value: platformVersionEffective }
              { name: 'CLOUDGRANGE_UPDATE_CHANNEL_URL',  value: updateChannelUrl }
              { name: 'CLOUDGRANGE_MODULE_CATALOG_URL',  value: moduleCatalogUrl }
              { name: 'CLOUDGRANGE_PLATFORM_UPDATER_ENABLED', value: 'true' }
              // The other two Container Apps the updater retags, and the flexible server it
              // takes an on-demand backup of before it does.
              { name: 'CLOUDGRANGE_ACA_PORTAL_APP_NAME', value: portalAppNameEffective }
              { name: 'CLOUDGRANGE_ACA_RELAY_APP_NAME',  value: relayAppNameEffective }
              { name: 'CLOUDGRANGE_ACA_POSTGRES_SERVER', value: postgresServerNameEffective }
              // AB#9171 (E9): the api-version the on-demand backup PUT is issued at. The
              // executor defaults to 2023-12-01-preview, and Azure answers that with
              // "405 MethodNotAllowed: The HTTP method 'PUT' is not supported on the resource
              // .../flexibleServers/<name>/backups/<backup>" — the backups sub-resource only
              // accepts a write on a newer api-version. Found on a live update, which was
              // correctly refused rather than proceeding without a backup. This is the version
              // `az postgres flexible-server backup create` itself uses; verified against this
              // subscription, where the same PUT returns 202 and the backup appears.
              { name: 'CLOUDGRANGE_ACA_POSTGRES_API_VERSION', value: postgresBackupApiVersion }
              // Same bootstrap token the relay app holds: the API seeds the matching
              // enrolment row when first-run setup completes, which is what lets the
              // built-in relay finish enrolling instead of retrying 401 forever.
              { name: 'RELAY_ENROLLMENT_TOKEN',          secretRef: 'relay-enrollment-token' }
              { name: 'CLOUDGRANGE_PORTAL_URL',          value: portalPublicUrl }
              // Modules call the platform here. Same reasoning as RELAY_PAAS_URL: the
              // external FQDN has a publicly trusted certificate, the internal one does not.
              { name: 'CLOUDGRANGE_API_INTERNAL_URL',    value: apiPublicUrl }
              // AB#9171 (E9) — the backchannel address for Keycloak's admin REST API and the
              // client-credentials token request. It is deliberately NOT the authority:
              // Keycloak__Authority must stay the PUBLIC issuer (the portal origin), because
              // that is what Keycloak mints tokens for and what browsers and the CLI present.
              // Admin calls cannot use it, because /admin is never published through the
              // portal — only /realms/cloudgrange and the theme path are.
              { name: 'Keycloak__InternalUrl',           value: 'http://${keycloakInternalFqdn}' }
            ], oidcPreseed ? oidcApiEnv : keycloakApiEnv)
            // AB#1667 — health probes (HIGH security/reliability finding)
            // Probe endpoints defined in design/observability/health-check-contract.md
            probes: [
              {
                type: 'Startup'
                httpGet: { path: '/health/startup', port: apiAppTargetPort, scheme: 'HTTP' }
                initialDelaySeconds: 5
                periodSeconds: 5
                failureThreshold: 12
              }
              {
                type: 'Liveness'
                httpGet: { path: '/health/live', port: apiAppTargetPort, scheme: 'HTTP' }
                periodSeconds: 30
                failureThreshold: 3
              }
              {
                type: 'Readiness'
                httpGet: { path: '/health/ready', port: apiAppTargetPort, scheme: 'HTTP' }
                periodSeconds: 10
                failureThreshold: 3
              }
            ]
            // AB#9171 (E9) — the data-protection key ring must outlive a revision.
            volumeMounts: [
              { volumeName: 'api-secrets', mountPath: '/etc/cloudgrange' }
            ]
          }
        ],
        // AB#1600 — optionally add PgBouncer sidecar for connection pooling
        enablePgBouncer ? [ pgBouncerContainer ] : []
      )
      // AB#9171 (E9)
      volumes: [
        { name: 'api-secrets', storageType: 'AzureFile', storageName: 'api-secrets' }
      ]
      // AB#1599 — HTTP scaling rule: scale at concurrentRequests per replica (HIGH performance finding)
      scale: {
        minReplicas: apiAppMinReplicas
        maxReplicas: apiAppMaxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: string(apiAppScaleThreshold)
              }
            }
          }
        ]
      }
    }
  }
  // AB#2374/2375 — also depend on the Entra client secret + App Insights secret writes to KV
  // so the KV references resolve before ACA revision activation.
  dependsOn: [ pgPasswordSecret, masterKeySecret, appInsightsSecret, kvRoleAssignNew, keycloakApiClientSecretResource, relayEnrollmentTokenSecret, apiSecretsStorage ]
}

// =============================================================================
// Portal Container App (external ingress on 80, same-origin nginx proxy)
// AB#1599 — HTTP scaling rule
// AB#1667 — health probe (TCP liveness on port 80)
// =============================================================================

resource portalApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: portalAppNameEffective
  location: location
  tags: union(allTagsBase, portalAppTags)
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: portalAppTargetPort
        transport: 'auto'
        // AB#1606: bind custom domain + managed TLS certificate when portalCustomDomain is provided.
        customDomains: empty(portalCustomDomain) ? [] : [
          {
            name: portalCustomDomain
            bindingType: 'SniEnabled'
            certificateId: null
          }
        ]
      }
      registries: registries
      secrets: imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
    }
    template: {
      containers: [
        {
          name: 'cloudgrange-portal'
          image: portalImage
          resources: { cpu: json(portalAppCpu), memory: portalAppMemory }
          env: [
            // Browser-facing API base — EMPTY = relative paths via portal nginx proxy (same-origin).
            { name: 'CLOUDGRANGE_API_URL', value: '' }
            { name: 'CLOUDGRANGE_AUTH_URL', value: oidcPreseed ? entraAuthority : keycloakPublicAuthority }
            // AB#9171 (E9) — the portal is the single public origin, so it proxies Keycloak the
            // same way the chart's Traefik Ingress does on Kubernetes.
            //
            // CLOUDGRANGE_KEYCLOAK_REALM_PROXY is what turns the /realms/cloudgrange block on,
            // and it is deliberately a separate switch from the upstream: the Kubernetes paths
            // already set CLOUDGRANGE_KEYCLOAK_UPSTREAM for Keycloak's theme assets, so keying
            // the realm proxy off the upstream would make the portal claim /realms/cloudgrange
            // on every K3s and AKS install and fight the chart's Ingress for it. Left unset
            // everywhere but here.
            //
            // /admin is never proxied. The portal's own regex block already routes every
            // Keycloak theme-resources version, so nothing here pins one — pinning would break
            // the moment the Keycloak image changes.
            { name: 'CLOUDGRANGE_KEYCLOAK_UPSTREAM', value: oidcPreseed ? '' : 'https://${keycloakInternalFqdn}' }
            { name: 'CLOUDGRANGE_KEYCLOAK_HOST', value: oidcPreseed ? '' : keycloakInternalFqdn }
            { name: 'CLOUDGRANGE_KEYCLOAK_REALM_PROXY', value: oidcPreseed ? 'false' : 'true' }
            { name: 'CLOUDGRANGE_API_UPSTREAM', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
            { name: 'CLOUDGRANGE_API_HOST', value: apiApp.properties.configuration.ingress.fqdn }
            { name: 'CLOUDGRANGE_FWD_PROTO', value: 'https' }
            { name: 'CLOUDGRANGE_API_INTERNAL_URL', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
          ]
          // AB#1667 — portal health probe: TCP liveness on port 80.
          // Portal is nginx serving static files; TCP probe avoids API dependency.
          // AB#2378 — HTTP readiness probe on / (port 80). nginx returns 200 on /
          // as soon as it finishes starting; this gates traffic until nginx is ready.
          probes: [
            {
              type: 'Liveness'
              tcpSocket: { port: portalAppTargetPort }
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/', port: portalAppTargetPort, scheme: 'HTTP' }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ]
      // AB#1599 — HTTP scaling rule for portal (MEDIUM performance finding)
      scale: {
        minReplicas: portalAppMinReplicas
        maxReplicas: portalAppMaxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: string(portalAppScaleThreshold)
              }
            }
          }
        ]
      }
    }
  }
}

// =============================================================================
// AB#9171 (E9) — Keycloak Container App (internal ingress)
//
// The identity tier the rest of the product assumes. It is NOT publicly exposed: the portal
// proxies /realms/cloudgrange and the Keycloak theme assets to it, which is exactly what
// the chart's Traefik Ingress does on every Kubernetes path. KC_HOSTNAME is therefore the
// portal's public URL and KC_PROXY_HEADERS=xforwarded makes Keycloak trust the proxy's
// X-Forwarded-* headers, so issuer and redirect URLs come out as the browser sees them.
//
// The realm is imported from the SAME file the Helm chart ships, projected as a file through
// an ACA secret volume (secret volumes take a per-secret `path`, which is how it can land with
// its .json extension — ACA secret NAMES cannot contain a dot). Keycloak substitutes
// ${CLOUDGRANGE_HOSTNAME} and ${KEYCLOAK_API_CLIENT_SECRET} from the environment during import.
// `start --import-realm` is a no-op when the realm already exists, so a redeploy is safe.
//
// Keycloak shares the platform database, as it does in the chart (KC_DB_URL points at the same
// database as the API), so there is no second server to provision or back up.
// =============================================================================

resource keycloakApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: keycloakAppNameEffective
  location: location
  tags: union(allTagsBase, keycloakAppTags)
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${miId}': {} }
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // Internal only — the portal is the single public origin for authentication.
        external: false
        targetPort: 8080
        transport: 'auto'
        // Container Apps ingress redirects plain HTTP to HTTPS unless this is set, and both
        // callers here speak plain HTTP to Keycloak on purpose: the portal's nginx proxy and
        // the API's backchannel admin calls. This is traffic inside one Container Apps
        // environment that never leaves it, which is the same position the Helm chart takes
        // when the API talks to the Keycloak Service over http inside the cluster.
        allowInsecure: true
        traffic: [ { weight: 100, latestRevision: true } ]
      }
      registries: registries
      secrets: concat(
        [
          { name: 'pg-password', keyVaultUrl: pgPasswordSecretUri, identity: miId }
          { name: 'kc-admin-user', keyVaultUrl: keycloakAdminUserSecretUri, identity: miId }
          { name: 'kc-admin-password', keyVaultUrl: keycloakAdminPasswordSecretUri, identity: miId }
          { name: 'kc-api-client-secret', keyVaultUrl: keycloakApiClientSecretUri, identity: miId }
          // The realm definition is not a credential, but it is the only way to project a file
          // into an ACA container without building a bespoke image.
          { name: 'realm-json', value: keycloakRealmJson }
        ],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: [
        {
          name: 'keycloak'
          image: keycloakImage
          args: [ 'start', '--import-realm' ]
          resources: { cpu: json(keycloakAppCpu), memory: keycloakAppMemory }
          env: [
            { name: 'KC_DB', value: 'postgres' }
            { name: 'KC_DB_URL', value: 'jdbc:postgresql://${pgFqdn}:5432/${postgresDatabaseName}?sslmode=require' }
            { name: 'KC_DB_USERNAME', value: postgresAdminUser }
            { name: 'KC_DB_PASSWORD', secretRef: 'pg-password' }
            { name: 'KC_HOSTNAME', value: portalPublicUrl }
            { name: 'KC_HOSTNAME_BACKCHANNEL_DYNAMIC', value: 'true' }
            { name: 'KC_PROXY_HEADERS', value: 'xforwarded' }
            { name: 'KC_HTTP_PORT', value: '8080' }
            { name: 'KC_HTTP_ENABLED', value: 'true' }
            { name: 'KC_HEALTH_ENABLED', value: 'true' }
            { name: 'KC_BOOTSTRAP_ADMIN_USERNAME', secretRef: 'kc-admin-user' }
            { name: 'KC_BOOTSTRAP_ADMIN_PASSWORD', secretRef: 'kc-admin-password' }
            { name: 'KEYCLOAK_API_CLIENT_SECRET', secretRef: 'kc-api-client-secret' }
            { name: 'CLOUDGRANGE_HOSTNAME', value: replace(portalPublicUrl, 'https://', '') }
          ]
          volumeMounts: [
            { volumeName: 'realm-import', mountPath: '/opt/keycloak/data/import' }
          ]
          probes: [
            {
              type: 'Readiness'
              // Keycloak serves health on the management port (9000), not the HTTP port.
              httpGet: { path: '/health/ready', port: 9000, scheme: 'HTTP' }
              initialDelaySeconds: 30
              periodSeconds: 15
              failureThreshold: 20
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'realm-import'
          storageType: 'Secret'
          secrets: [ { secretRef: 'realm-json', path: 'cloudgrange-realm.json' } ]
        }
      ]
      // Keycloak is not horizontally scaled here: one replica, always on. Scale-to-zero would
      // make the first sign-in of the day wait for a JVM cold start behind an auth redirect.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [ pgPasswordSecret, keycloakAdminUserSecret, keycloakAdminPasswordSecret, keycloakApiClientSecretResource, kvRoleAssignNew, pgDb, pgFwAzure ]
}

// =============================================================================
// AB#9171 (E9) — built-in relay Container App (internal ingress)
//
// The on-prem stack's built-in site relay, which is what makes cluster registration and job
// dispatch work. It enrols itself against the API with the shared bootstrap token and then
// keeps a persistent identity on Azure Files. Internal ingress: managed agents connect to it
// from inside the environment; exposing it publicly is a separate decision (relay 8443 TLS is
// still open on every path).
// =============================================================================

resource relayApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: relayAppNameEffective
  location: location
  tags: union(allTagsBase, relayAppTags)
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: relayPort
        transport: 'auto'
        traffic: [ { weight: 100, latestRevision: true } ]
      }
      registries: registries
      secrets: concat(
        [ { name: 'relay-enrollment-token', keyVaultUrl: relayEnrollmentTokenSecretUri, identity: miId } ],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: [
        {
          name: 'cloudgrange-relay'
          image: relayImage
          resources: { cpu: json(relayAppCpu), memory: relayAppMemory }
          env: [
            // The API's EXTERNAL FQDN, not the internal one. The relay is a .NET client that
            // validates the server certificate, and the environment's certificate does not
            // cover the second-level *.internal.<domain> name. nginx (the portal) can ignore
            // that; a .NET HttpClient cannot.
            { name: 'RELAY_PAAS_URL', value: apiPublicUrl }
            { name: 'RELAY_ENROLLMENT_TOKEN', secretRef: 'relay-enrollment-token' }
            { name: 'RELAY_DISPLAY_NAME', value: 'site-relay' }
            { name: 'RELAY_LISTEN_PORT', value: string(relayPort) }
            { name: 'RELAY_IDENTITY_DIR', value: '/var/lib/cloudgrange-relay/identity' }
            // AB#9171 (E9): the SQLite agent registry and job queue go on the replica's own
            // storage, NOT on the Azure Files share above. SQLite on SMB fails outright —
            // "SQLite Error 5: 'database is locked'" the moment the registry and the queue
            // both open agents.db — and the relay never starts. The share still holds
            // relay.key, which is what has to survive a revision roll so the relay stays ONE
            // relay instead of re-enrolling and orphaning its site after every update.
            { name: 'RELAY_STATE_DIR', value: '/var/lib/cloudgrange-relay/state' }
            { name: 'CLOUDGRANGE_VERSION', value: _relayImageTagEff }
          ]
          volumeMounts: [
            { volumeName: 'relay-identity', mountPath: '/var/lib/cloudgrange-relay/identity' }
          ]
        }
      ]
      volumes: [
        { name: 'relay-identity', storageType: 'AzureFile', storageName: 'relay-identity' }
      ]
      // One relay, always on: it holds a single enrolled identity and a live connection to the API.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  // The managed identity must be able to read the enrolment token from Key Vault; the identity
  // block is omitted because the relay itself needs no ARM access — the secret reference does.
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${miId}': {} }
  }
  dependsOn: [ relayEnrollmentTokenSecret, kvRoleAssignNew, relayIdentityStorage, apiApp ]
}

// =============================================================================
// AB#9171 (E9) — role assignments for in-app Platform updates.
//
// The in-app updater on this path is the API's ContainerAppsExecutor: it retags each
// CloudGrange container and lets ACA roll a new revision, and it takes an on-demand
// PostgreSQL backup first. Both need ARM rights, and the whole point of E9 is that the
// platform provisions them rather than an operator granting them by hand.
//
// Scope is deliberately per-resource, not the resource group: the identity can change the
// three Container Apps it is allowed to update and nothing else. "Container Apps Contributor"
// is the narrowest built-in role that can PATCH a containerApp. For the database there is no
// built-in role that grants only the on-demand backup operation
// (Microsoft.DBforPostgreSQL/flexibleServers/backups/write), so Contributor is used, scoped to
// the single flexible server.
// =============================================================================

var containerAppsContributorRoleId = '358470bc-b998-42bd-ab17-a7e34c199c0f'
var contributorRoleId              = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var keyVaultSecretsOfficerRoleId   = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

// AB#9171 (E9) — the deploying identity must be able to READ the bootstrap secrets it wrote.
//
// Creating the vault takes Contributor; reading a secret out of it takes a data-plane role,
// and the vault uses RBAC authorization. Without this, a redeploy cannot find the secrets it
// stored on the first install, generates fresh ones, and the template overwrites them —
// silently rotating the master key out from under a database that was encrypted with the old
// one. That is exactly what happened on a real second deployment: the API came up with
// "CG-SECRETS-ERROR-0006: the master key does not match the active key version recorded in
// the database" and the built-in secret store failed closed.
//
// The generate-once guarantee is the whole point of provisioning the platform's own secrets,
// so the right fix is to give the installer the access its own design assumes, scoped to this
// one vault. The installer also refuses to continue on any read error other than "not found",
// so a missing grant can never again be mistaken for a first install.
resource deployerKeyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(byoKvId)) {
  scope: newKv
  name: guid(newKv.id, deployer().objectId, keyVaultSecretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId: deployer().objectId
  }
}

resource apiAppUpdateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apiApp
  name: guid(apiApp.id, miId, containerAppsContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', containerAppsContributorRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource portalAppUpdateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: portalApp
  name: guid(portalApp.id, miId, containerAppsContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', containerAppsContributorRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource relayAppUpdateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: relayApp
  name: guid(relayApp.id, miId, containerAppsContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', containerAppsContributorRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource pgBackupRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: pg
  name: guid(pg.id, miId, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// AB#1668 — Azure Monitor metric alert rules module
// =============================================================================

module alertRules 'monitoring.bicep' = if (enableAlertRules) {
  name: 'cloudgrange-alerts'
  params: {
    workload: workload
    environment: environment
    regionCode: regionCode
    instance: instance
    allTagsBase: allTagsBase
    apiAppId: apiApp.id
    portalAppId: portalApp.id
    pgServerId: pg.id
    kvId: empty(byoKvId) ? newKv.id : existingKv.id
    ownerEmail: contains(commonTags, 'Owner') ? commonTags.Owner : ''
  }
}

// =============================================================================
// Outputs
// =============================================================================
output portalUrl string = 'https://${portalApp.properties.configuration.ingress.fqdn}'
output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output apiAppName string = apiApp.name
output portalAppName string = portalApp.name
// AB#9171 (E9)
output keycloakAppName string = keycloakApp.name
output relayAppName string = relayApp.name
output platformVersion string = platformVersionEffective
output updateChannelUrl string = updateChannelUrl
output postgresServer string = pgFqdn
output keyVaultName string = empty(byoKvId) ? newKv.name : existingKv.name

// AB#1600 — appInsightsConnectionString marked @secure() (HIGH security finding)
// App Insights connection strings contain the instrumentation key — treat as sensitive.
@secure()
output appInsightsConnectionString string = appiConnectionString

output managedIdentityClientId string = miClientId
output azureMonitorWorkspaceId string = amwId
output azureMonitorQueryEndpoint string = amwQueryEndpoint
output azureMonitorMetricsIngestionEndpoint string = dceMetricsIngestionEndpoint
output azureMonitorDcrImmutableId string = dcrImmutableId
