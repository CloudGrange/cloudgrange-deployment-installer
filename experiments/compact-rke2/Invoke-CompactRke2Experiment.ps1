#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap the version-pinned Compact RKE2 experiment on a dedicated Linux VM.
.NOTES
    Author: Kristopher Turner
    TaskReference: AB#8913 AB#8914
    This experiment does not install or qualify the assembled CloudGrange product.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateSet('Plan','Install','Verify')][string]$Mode = 'Plan'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-ExperimentNative {
    param([Parameter(Mandatory)][string]$Command,[string[]]$Arguments = @())
    $output = @(& $Command @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ('Native command failed: '+$Command+' (exit '+$code+'). Inspect the retained host state.') }
    return ($output -join "`n")
}

function Test-ExperimentArtifacts {
    param([Parameter(Mandatory)][object]$Manifest,[Parameter(Mandatory)][string]$Directory)
    if ($Manifest.schema_version -ne 1 -or $Manifest.profile -ne 'Compact' -or $Manifest.qualification -ne 'experiment' -or
        $Manifest.os -ne 'Ubuntu24.04' -or $Manifest.architecture -ne 'x86_64' -or $Manifest.rke2_version -ne 'v1.36.4+rke2r1' -or
        $Manifest.canal_chart -ne 'v3.32.1-build2026082700' -or $Manifest.traefik_chart -ne '40.1.010' -or
        $Manifest.rke2_binary_sha256 -ne 'aa7eea8ec905b89ec9a91443cbe96ddb6cd0fc7d15e422380e192b011e4e130b') { throw 'Unsupported experiment manifest.' }
    $expectedNames = @('rke2.linux-amd64.tar.gz','rke2-images.linux-amd64.tar.zst')
    if (@($Manifest.artifacts).Count -ne 2 -or @(Compare-Object $expectedNames @($Manifest.artifacts.name)).Count) { throw 'Unexpected artifact set.' }
    foreach ($artifact in $Manifest.artifacts) {
        if ($artifact.sha256 -notmatch '^[a-f0-9]{64}$' -or $artifact.bytes -le 0) { throw 'Invalid immutable artifact metadata.' }
        $path = Join-Path $Directory $artifact.name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $artifact.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) {
            throw ('Artifact content rejected before installation: '+$artifact.name)
        }
    }
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
# Validate original bytes before creating any Linux installation state.
Test-ExperimentArtifacts -Manifest $manifest -Directory $ArtifactDirectory
if (-not $IsLinux -or (Invoke-ExperimentNative id @('-u')).Trim() -ne '0') { throw 'Run this experiment as root under PowerShell7 on the dedicated Linux management VM.' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($config.schema_version -ne 1 -or $config.profile -ne 'Compact' -or $config.node_name -notmatch '^[a-z][a-z0-9-]{1,62}$' -or
    $config.processors -ne 8 -or $config.memory_gb -ne 32 -or $config.system_disk_gb -ne 200 -or $config.data_disk_gb -ne 256 -or
    $config.data_mount -ne '/var/lib/rancher' -or $config.cluster_cidr -ne '10.42.0.0/16' -or $config.service_cidr -ne '10.43.0.0/16' -or
    $config.cluster_dns -ne '10.43.0.10' -or $config.ready_timeout_minutes -ne 20) { throw 'Unsupported Compact experiment inputs.' }
$nodeAddress = $null
if (-not [Net.IPAddress]::TryParse($config.node_ip,[ref]$nodeAddress) -or $nodeAddress.AddressFamily -ne 'InterNetwork' -or
    $config.node_ip -match '^10\.(42|43)\.' -or $config.node_ip -match '^(0|127|169\.254)\.') { throw 'Invalid or overlapping node IPv4 address.' }
$os = Get-Content /etc/os-release -Raw
if ($os -notmatch '(?m)^ID=ubuntu$' -or $os -notmatch '(?m)^VERSION_ID="24\.04"$' -or
    (Invoke-ExperimentNative uname @('-m')).Trim() -ne 'x86_64' -or (Invoke-ExperimentNative hostname).Trim() -ne $config.node_name) { throw 'Unexpected management OS, architecture or hostname.' }
if (-not (Test-Path /run/systemd/system) -or [int](Invoke-ExperimentNative nproc) -ne $config.processors) { throw 'Expected systemd and the assigned eight processors.' }
$memory = [regex]::Match((Get-Content /proc/meminfo -Raw),'(?m)^MemTotal:\s+(\d+) kB')
if (-not $memory.Success -or [long]$memory.Groups[1].Value*1KB -lt 30GB) { throw 'Management VM memory is below the32GiB assignment tolerance.' }
$addresses = Invoke-ExperimentNative ip @('-j','-4','address','show') | ConvertFrom-Json
if (@($addresses | ForEach-Object addr_info | Where-Object local -eq $config.node_ip).Count -ne 1) { throw 'Configured node address is not assigned exactly once.' }
$blocks = Invoke-ExperimentNative lsblk @('-b','-J','-o','NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS') | ConvertFrom-Json
$systemDisk = @($blocks.blockdevices | Where-Object { $_.name -eq 'sda' -and $_.size -eq 200GB })
$dataDisk = @($blocks.blockdevices | Where-Object { $_.name -eq 'sdb' -and $_.size -eq 256GB })
if ($systemDisk.Count -ne 1 -or $dataDisk.Count -ne 1 -or
    @($systemDisk[0].children | Where-Object { $_.mountpoints -contains '/' -and $_.size -ge 190GB }).Count -ne 1 -or
    @($dataDisk[0].children | Where-Object { $_.label -eq 'CGLABDATA' -and $_.fstype -eq 'ext4' -and $_.mountpoints -contains $config.data_mount }).Count -ne 1) {
    throw 'The required independent system/data disk layout is not mounted.'
}
$iptables = (Invoke-ExperimentNative iptables @('--version')).Trim()
$ntpSynchronized = (Invoke-ExperimentNative timedatectl @('show','--property=NTPSynchronized','--value')).Trim()
if ($ntpSynchronized -ne 'yes') { throw 'Management time synchronization is not established.' }
$freeData = (Invoke-ExperimentNative df @('-B1','--output=avail',$config.data_mount) -split "`n")[-1].Trim()
if ([long]$freeData -lt 100GB) { throw 'Experiment data volume needs at least100GiB free headroom.' }

$requestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(
    (Get-Content $ConfigPath -Raw)+(Get-Content $ManifestPath -Raw)+(Get-Content $PSCommandPath -Raw)))).ToLowerInvariant()
$stateDirectory = '/var/lib/cloudgrange/compact-rke2-experiment'
$checkpointPath = Join-Path $stateDirectory 'checkpoint.json'
$rkeConfigPath = '/etc/rancher/rke2/config.yaml'
$runtimeConfig = @"
node-name: $($config.node_name)
node-ip: $($config.node_ip)
advertise-address: $($config.node_ip)
tls-san:
  - $($config.node_name)
  - $($config.node_ip)
cni: canal
ingress-controller: traefik
cluster-cidr: $($config.cluster_cidr)
service-cidr: $($config.service_cidr)
cluster-dns: $($config.cluster_dns)
data-dir: /var/lib/rancher/rke2
write-kubeconfig-mode: '0600'
"@
$checkpoint = $null
if (Test-Path $checkpointPath) {
    $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json
    if ($checkpoint.request_sha256 -ne $requestHash) { throw 'Existing experiment belongs to different inputs/source; preserved.' }
} elseif ((Test-Path '/usr/local/bin/rke2') -or (Test-Path '/var/lib/rancher/rke2/server') -or (Test-Path $rkeConfigPath)) {
    throw 'Existing runtime has no matching experiment checkpoint; preserved.'
}
if ((Test-Path $rkeConfigPath) -and (Get-Content $rkeConfigPath -Raw).TrimEnd() -cne $runtimeConfig.TrimEnd()) { throw 'Existing RKE2 configuration differs; preserved.' }
if ($Mode -eq 'Plan') {
    @{mode=$Mode;profile='Compact';hostname=$config.node_name;request_sha256=$requestHash;artifacts_verified=$true;iptables=$iptables;
        time_synchronized=$true;data_free_bytes=[long]$freeData;existing_checkpoint=[bool]$checkpoint;runtime_started=$false} | ConvertTo-Json -Compress
    return
}
if ($Mode -eq 'Verify' -and -not $checkpoint) { throw 'No experiment checkpoint to verify.' }
New-Item -ItemType Directory -Path $stateDirectory,$EvidenceDirectory -Force | Out-Null
$null = Invoke-ExperimentNative chmod @('0700',$stateDirectory,$EvidenceDirectory)
function Save-ExperimentCheckpoint {
    param([string]$Phase)
    @{request_sha256=$requestHash;phase=$Phase;runtime=$manifest.rke2_version;node=$config.node_name;updated_utc=[DateTimeOffset]::UtcNow} |
        ConvertTo-Json | Set-Content -LiteralPath $checkpointPath
}
if ($Mode -eq 'Install') {
    if (-not $checkpoint) { Save-ExperimentCheckpoint 'artifacts_verified' }
    $archive = Join-Path $ArtifactDirectory 'rke2.linux-amd64.tar.gz'
    $members = @((Invoke-ExperimentNative tar @('-tzf',$archive)) -split "`n" | ForEach-Object { $_ -replace '^\./','' })
    $allowed = @('','bin/','bin/rke2','bin/rke2-killall.sh','bin/rke2-uninstall.sh','lib/','lib/systemd/',
        'lib/systemd/system/','lib/systemd/system/rke2-server.service','lib/systemd/system/rke2-server.env',
        'lib/systemd/system/rke2-agent.service','lib/systemd/system/rke2-agent.env','share/','share/rke2/',
        'share/rke2/rke2-cis-sysctl.conf','share/rke2/LICENSE.txt')
    if (@($members | Where-Object { $_ -notin $allowed }).Count -or 'bin/rke2' -notin $members) { throw 'Unexpected vendor archive member; no extraction.' }
    # Preserve the official tarball layout and systemd units. No first-party shell
    # installer is generated, and vendor uninstall/killall scripts are not invoked.
    if (Test-Path '/usr/local/bin/rke2') {
        if ((Get-FileHash '/usr/local/bin/rke2' -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.rke2_binary_sha256) {
            throw 'Existing RKE2 executable differs; preserved without replacement.'
        }
    } else { $null = Invoke-ExperimentNative tar @('-xzf',$archive,'-C','/usr/local') }
    if ((Get-FileHash '/usr/local/bin/rke2' -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.rke2_binary_sha256) { throw 'Extracted binary differs.' }
    New-Item -ItemType Directory -Path '/etc/rancher/rke2','/var/lib/rancher/rke2/agent/images' -Force | Out-Null
    $runtimeConfig | Set-Content -LiteralPath $rkeConfigPath -Encoding utf8NoBOM
    $null = Invoke-ExperimentNative chmod @('0600',$rkeConfigPath)
    $imageTarget = '/var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst'
    if (-not (Test-Path $imageTarget)) { Copy-Item -LiteralPath (Join-Path $ArtifactDirectory 'rke2-images.linux-amd64.tar.zst') -Destination $imageTarget }
    $imageDigest = ($manifest.artifacts | Where-Object name -eq 'rke2-images.linux-amd64.tar.zst').sha256
    if ((Get-FileHash $imageTarget -Algorithm SHA256).Hash.ToLowerInvariant() -ne $imageDigest) { throw 'Cached image archive differs; runtime not started.' }
    $binaryVersion = Invoke-ExperimentNative /usr/local/bin/rke2 @('--version')
    if ($binaryVersion -notmatch [regex]::Escape($manifest.rke2_version)) { throw 'Installed RKE2 binary version differs.' }
    $null = Invoke-ExperimentNative systemctl @('daemon-reload')
    Save-ExperimentCheckpoint 'runtime_prepared'
    $null = Invoke-ExperimentNative systemctl @('enable','rke2-server.service')
    $null = Invoke-ExperimentNative systemctl @('start','--no-block','rke2-server.service')
    Save-ExperimentCheckpoint 'runtime_start_requested'
}
$watch = [Diagnostics.Stopwatch]::StartNew()
$kubectl = '/var/lib/rancher/rke2/bin/kubectl'
$kubeArguments = @('--kubeconfig','/etc/rancher/rke2/rke2.yaml','--request-timeout=10s')
$ready = $false
do {
    if ((Test-Path $kubectl) -and (Test-Path '/etc/rancher/rke2/rke2.yaml')) {
        $null = & $kubectl @kubeArguments get --raw=/readyz 2>&1
        if ($LASTEXITCODE -eq 0) {
            $nodeText = @(& $kubectl @kubeArguments get nodes -o json 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0) {
                $nodes = $nodeText | ConvertFrom-Json
                $ready = @($nodes.items).Count -eq 1 -and $nodes.items[0].metadata.name -eq $config.node_name -and
                    @($nodes.items[0].status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1
            }
        }
    }
    if (-not $ready) { Start-Sleep -Seconds 10 }
} until ($ready -or $watch.Elapsed.TotalMinutes -ge $config.ready_timeout_minutes)
if (-not $ready) { Save-ExperimentCheckpoint 'readiness_timeout'; throw 'RKE2 did not become Ready within the20-minute experiment threshold. Existing runtime and logs preserved; no retry or teardown.' }
$pods = Invoke-ExperimentNative $kubectl ($kubeArguments+@('get','pods','--all-namespaces','-o','json')) | ConvertFrom-Json
$charts = Invoke-ExperimentNative $kubectl ($kubeArguments+@('get','helmcharts.helm.cattle.io','-n','kube-system','-o','json')) | ConvertFrom-Json
$nodeText | Set-Content (Join-Path $EvidenceDirectory 'nodes.json')
$pods | ConvertTo-Json -Depth 70 | Set-Content (Join-Path $EvidenceDirectory 'pods.json')
$charts | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $EvidenceDirectory 'charts.json')
Save-ExperimentCheckpoint 'node_ready'
$result = @{mode=$Mode;profile='Compact';request_sha256=$requestHash;runtime=$manifest.rke2_version;hostname=$config.node_name;
    node_ready=$true;readiness_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2);pod_count=@($pods.items).Count;
    all_addons_qualified=$false;restart_qualified=$false;egress_denied_experiment_qualified=$false;ha_qualified=$false;product_qualified=$false;
    completed_utc=[DateTimeOffset]::UtcNow}
$result | ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory 'bootstrap-result.json')
$result | ConvertTo-Json -Compress
