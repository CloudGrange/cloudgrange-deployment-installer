#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1593 — Generate a self-signed TLS certificate for the CloudSmith nginx sidecar.
#
# Called by Deploy-DockerCompose during install to populate the nginx_certs Docker volume
# before the nginx container starts.  The certificate is created inside the guest VM
# (or WSL2 environment) using openssl, which is present on all supported Linux guests.
#
# The generated cert is:
#   - RSA 2048-bit, SHA-256
#   - Valid for 3650 days (~10 years) — replaced by a CA-signed cert in production
#   - SAN includes the VM IP and localhost
#
# Usage:
#   Called internally by Deploy-DockerCompose.ps1.
#   Can also be run standalone:
#     .\New-SelfSignedCert.ps1 -VmIp 192.168.100.10 -SshKeyPath $keyPath
#
# Parameters:
#   VmIp        — IP address of the CloudSmith VM (added to SAN)
#   Hostname    — Hostname for CN / SAN (defaults to 'cloudsmith')
#   ComposeDir  — Path inside the guest where compose files live (default: /opt/cloudsmith)
#   SshKeyPath  — SSH private key for guest access (preferred)
#   Credential  — PSCredential for Hyper-V Direct when SshKeyPath is not available
#   VmName      — Hyper-V VM name (used with Credential)
#   UseWsl2     — Switch: use WSL2 instead of a Hyper-V VM

[CmdletBinding()]
param(
    [string]$VmIp       = '192.168.100.10',
    [string]$Hostname   = 'cloudsmith',
    [string]$ComposeDir = '/opt/cloudsmith',
    [string]$SshKeyPath = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string]$VmName     = 'cloudsmith-docker',
    [switch]$UseWsl2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The bash script that runs inside the Linux guest.
# It writes cloudsmith.crt and cloudsmith.key into the nginx_certs Docker volume
# by running a temporary Alpine container that mounts the volume.
#
# AB#2347 — Defensive migration: if a previous install populated the volume with
# server.crt/server.key (openssl defaults from a hand-deployed or pre-AB#1593 install),
# rename them to cloudsmith.crt/cloudsmith.key before regenerating. This prevents nginx
# from restart-looping on the "cloudsmith.crt: No such file" error.
$bashScript = @"
set -euo pipefail

CERT_DIR="/tmp/cloudsmith-certs-$$"
mkdir -p "\$CERT_DIR"

# AB#2347: Migrate any legacy server.crt/server.key in the volume to cloudsmith.crt/cloudsmith.key
# so nginx can boot regardless of how the volume was first populated.
docker volume inspect cloudsmith_nginx_certs >/dev/null 2>&1 && docker run --rm \
    -v cloudsmith_nginx_certs:/certs \
    alpine:latest \
    sh -c '
        if [ -f /certs/server.crt ] && [ ! -f /certs/cloudsmith.crt ]; then
            echo "Migrating legacy server.crt -> cloudsmith.crt"
            mv /certs/server.crt /certs/cloudsmith.crt
        fi
        if [ -f /certs/server.key ] && [ ! -f /certs/cloudsmith.key ]; then
            echo "Migrating legacy server.key -> cloudsmith.key"
            mv /certs/server.key /certs/cloudsmith.key
        fi
        exit 0
    ' || true

# Generate openssl config with SANs
cat > "\$CERT_DIR/openssl.cnf" <<OPENSSL_EOF
[req]
distinguished_name = req_dn
x509_extensions    = v3_req
prompt             = no

[req_dn]
CN = $Hostname

[v3_req]
subjectAltName = @alt_names
keyUsage       = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $Hostname
DNS.2 = localhost
IP.1  = $VmIp
IP.2  = 127.0.0.1
OPENSSL_EOF

# Generate private key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "\$CERT_DIR/cloudsmith.key" \
    -out    "\$CERT_DIR/cloudsmith.crt" \
    -config "\$CERT_DIR/openssl.cnf" 2>/dev/null

echo "Certificate generated."
openssl x509 -in "\$CERT_DIR/cloudsmith.crt" -noout -subject -dates 2>/dev/null

# Copy certs into the nginx_certs Docker volume via a temporary alpine container.
# The volume is named {compose_project_name}_nginx_certs; compose project = 'cloudsmith'.
docker run --rm \
    -v cloudsmith_nginx_certs:/certs \
    -v "`${CERT_DIR}:/src:ro" \
    alpine:latest \
    sh -c "cp /src/cloudsmith.crt /certs/cloudsmith.crt && cp /src/cloudsmith.key /certs/cloudsmith.key && chmod 644 /certs/cloudsmith.crt && chmod 600 /certs/cloudsmith.key"

echo "Certificates installed into nginx_certs volume."
rm -rf "\$CERT_DIR"
"@

Write-Host "  Generating self-signed TLS certificate (RSA-2048, 3650 days, SAN: $VmIp / $Hostname)..."

if ($UseWsl2) {
    $bashScript | wsl -d Ubuntu -u root -- bash -s
    if ($LASTEXITCODE -ne 0) {
        Write-Error "New-SelfSignedCert: certificate generation failed in WSL2 (exit $LASTEXITCODE)."
    }
} elseif (-not [string]::IsNullOrEmpty($SshKeyPath)) {
    $sshOpts   = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
    $sshTarget = "cloudsmith@$VmIp"
    $bashScript | & ssh.exe @sshOpts $sshTarget 'sudo bash -s'
    if ($LASTEXITCODE -ne 0) {
        Write-Error "New-SelfSignedCert: certificate generation failed via SSH (exit $LASTEXITCODE)."
    }
} else {
    if ($null -eq $Credential) {
        $Credential = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
    }
    $session = New-PSSession -VMName $VmName -Credential $Credential
    Invoke-Command -Session $session -ScriptBlock { param($s) $s | sudo bash -s } -ArgumentList $bashScript
    Remove-PSSession $session
}

Write-Host "  TLS certificate installed into nginx_certs volume." -ForegroundColor Green
Write-Host "  Replace with a CA-signed certificate for production use." -ForegroundColor Yellow
