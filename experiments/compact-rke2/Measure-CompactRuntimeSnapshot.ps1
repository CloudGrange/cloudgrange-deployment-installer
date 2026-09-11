#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,11}$')][string]$SourceExecutionId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,11}$')][string]$CollectionExecutionId,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ManifestPath=(Join-Path $PSScriptRoot 'artifacts.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12
if(Test-Path -LiteralPath $OutputPath){throw 'Review destination exists; preserve the prior review.'}
$verification=Get-Content (Join-Path $EvidenceDirectory 'readback-verification.json') -Raw|ConvertFrom-Json -AsHashtable
$names=@('nodes.json','pods.json','charts.json','bootstrap-result.json','source-host-receipt.json')
if($verification.source_execution_id -cne $SourceExecutionId -or $verification.collection_execution_id -cne $CollectionExecutionId -or
    -not $verification.exact_original_files_verified -or @($verification.files).Count -ne 5 -or
    @(Compare-Object -CaseSensitive $names @($verification.files.name)).Count){throw 'Expected the verified original execution file set.'}
foreach($file in $verification.files){
    $path=Join-Path $EvidenceDirectory $file.name
    if((Get-Item -LiteralPath $path).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $file.sha256){throw 'Original observation bytes changed.'}
}
$manifest=Get-Content $ManifestPath -Raw|ConvertFrom-Json -AsHashtable
$nodes=Get-Content (Join-Path $EvidenceDirectory 'nodes.json') -Raw|ConvertFrom-Json -AsHashtable
$pods=Get-Content (Join-Path $EvidenceDirectory 'pods.json') -Raw|ConvertFrom-Json -AsHashtable
$charts=Get-Content (Join-Path $EvidenceDirectory 'charts.json') -Raw|ConvertFrom-Json -AsHashtable
$bootstrap=Get-Content (Join-Path $EvidenceDirectory 'bootstrap-result.json') -Raw|ConvertFrom-Json -AsHashtable
$receipt=Get-Content (Join-Path $EvidenceDirectory 'source-host-receipt.json') -Raw|ConvertFrom-Json -AsHashtable
if(@($nodes.items).Count -ne 1 -or $nodes.items[0].metadata.name -cne 'cglab-mgmt01' -or
    $nodes.items[0].status.nodeInfo.kubeletVersion -cne $manifest.rke2_version -or
    $bootstrap.request_sha256 -cne $verification.request_sha256 -or $receipt.execution_id -cne $SourceExecutionId -or
    @($pods.items).Count -ne $bootstrap.pod_count -or @($pods.items|Where-Object {$_.metadata.namespace -cne 'kube-system'}).Count){throw 'Runtime snapshot identity differs.'}
$findings=[Collections.Generic.List[string]]::new()
$conditions=$nodes.items[0].status.conditions
if(@($conditions|Where-Object {$_.type -eq 'Ready' -and $_.status -eq 'True'}).Count -ne 1){$findings.Add('Expected node is not Ready.')}
foreach($type in @('MemoryPressure','DiskPressure','PIDPressure','NetworkUnavailable')){
    if(@($conditions|Where-Object {$_.type -eq $type -and $_.status -eq 'False'}).Count -ne 1){$findings.Add('Node condition is not clear: '+$type)}
}
$podReview=@(foreach($pod in $pods.items){
    $containers=@($pod.status.containerStatuses)
    $healthy=($pod.status.phase -eq 'Running' -and $containers.Count -eq @($pod.spec.containers).Count -and
        @($containers|Where-Object {-not $_.ready}).Count -eq 0 -and
        @($pod.status.conditions|Where-Object {$_.type -eq 'Ready' -and $_.status -eq 'True'}).Count -eq 1) -or
        ($pod.status.phase -eq 'Succeeded' -and $pod.metadata.name -like 'helm-install-rke2-*' -and
        $containers.Count -gt 0 -and @($containers|Where-Object {$_.state.terminated.exitCode -ne 0}).Count -eq 0)
    if(-not $healthy){$findings.Add('Pod requires investigation: '+$pod.metadata.name)}
    [ordered]@{name=$pod.metadata.name;phase=$pod.status.phase;healthy_at_observation=$healthy;
        containers=@($containers|ForEach-Object {[ordered]@{name=$_.name;image=$_.image;image_id=$_.imageID;ready=$_.ready;
            restart_count=$_.restartCount;last_termination=$_.lastState['terminated']}})}
})
$chartReview=@(foreach($chart in $charts.items){
    $bytes=[Convert]::FromBase64String($chart.spec.chartContent)
    if($bytes.Length -gt 4MB){throw 'Embedded chart exceeds observation bound.'}
    $stream=[IO.MemoryStream]::new($bytes)
    $gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress)
    $reader=[System.Formats.Tar.TarReader]::new($gzip)
    $metadata=$null; $count=0
    try {
        while($null -ne ($entry=$reader.GetNextEntry())){
            if($entry.Name -ceq ($chart.metadata.name+'/Chart.yaml')){
                if($entry.Length -gt 64KB){throw 'Unexpected chart metadata size.'}
                $textReader=[IO.StreamReader]::new($entry.DataStream)
                try {$metadata=ConvertFrom-Yaml $textReader.ReadToEnd()} finally {$textReader.Dispose()}
                $count++
            }
        }
    } finally {$reader.Dispose();$gzip.Dispose();$stream.Dispose()}
    if($count -ne 1 -or $metadata.name -cne $chart.metadata.name){throw 'Expected one matching embedded chart metadata record.'}
    if(@($chart.status.conditions|Where-Object {$_.type -eq 'Failed' -and $_.status -eq 'False'}).Count -ne 1){$findings.Add('HelmChart failed or has no explicit failure status: '+$metadata.name)}
    $expected=switch($metadata.name){'rke2-canal' {$manifest.canal_chart};'rke2-traefik' {$manifest.traefik_chart};'rke2-traefik-crd' {$manifest.traefik_chart};default {$null}}
    if($expected -and $metadata.version -cne $expected){$findings.Add('Pinned chart version differs: '+$metadata.name)}
    [ordered]@{name=$metadata.name;chart_version=$metadata.version;chart_app_version=$metadata.appVersion;
        archive_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();pinned_version_match=if($expected){$metadata.version -ceq $expected}else{$null}}
})
foreach($name in @('rke2-canal','rke2-coredns','rke2-metrics-server','rke2-runtimeclasses','rke2-snapshot-controller','rke2-snapshot-controller-crd','rke2-traefik','rke2-traefik-crd')){
    if(@($chartReview|Where-Object name -CEQ $name).Count -ne 1){$findings.Add('Expected exactly one chart: '+$name)}
}
$result=[ordered]@{source_execution_id=$SourceExecutionId;collection_execution_id=$CollectionExecutionId;
    observed_utc=$bootstrap.completed_utc;reviewed_utc=[DateTimeOffset]::UtcNow;input_files=$verification.files;
    installer_commit=$receipt.installer_commit;request_sha256=$bootstrap.request_sha256;node=$nodes.items[0].status.nodeInfo;
    pods=$podReview;charts=$chartReview;findings=@($findings);snapshot_health_passed=($findings.Count -eq 0);
    historical_container_restarts=@($podReview|Where-Object {@($_.containers|Where-Object restart_count -gt 0).Count}|ForEach-Object {$_.name});
    functional_dns_ingress_qualified=$false;persistence_reboot_qualified=$false;restricted_egress_qualified=$false;product_qualified=$false}
$result|ConvertTo-Json -Depth 18|Set-Content -LiteralPath $OutputPath
if($findings.Count){throw ('Snapshot has '+$findings.Count+' findings; original inputs and review preserved.')}
Write-Output ('Snapshot component health passed: '+$podReview.Count+' pods, '+$chartReview.Count+' charts. Historical restarts and unqualified functional checks remain in the review.')
