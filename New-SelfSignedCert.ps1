#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1593 — Generate a self-signed TLS certificate for the CloudGrange nginx sidecar.
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
#   Dot-source this file, then call:
#     . .\New-SelfSignedCert.ps1
#     New-SelfSignedCert -VmIp 192.168.100.10 -SshKeyPath $keyPath
#
# Parameters:
#   VmIp        — IP address of the CloudGrange VM (added to SAN)
#   Hostname    — Hostname for CN / SAN (defaults to 'cloudgrange')
#   ComposeDir  — Path inside the guest where compose files live (default: /opt/cloudgrange)
#   SshKeyPath  — SSH private key for guest access (preferred)
#   Credential  — PSCredential for Hyper-V Direct when SshKeyPath is not available
#   VmName      — Hyper-V VM name (used with Credential)
#   UseWsl2     — Switch: use WSL2 instead of a Hyper-V VM

function New-SelfSignedCert {
    [CmdletBinding()]
    param(
        [string]$VmIp       = '192.168.100.10',
        [string]$Hostname   = 'cloudgrange',
        [string]$ComposeDir = '/opt/cloudgrange',
        [string]$SshKeyPath = '',
        [System.Management.Automation.PSCredential]$Credential = $null,
        [string]$VmName     = 'cloudgrange-docker',
        [switch]$UseWsl2
    )

    $ErrorActionPreference = 'Stop'

    # The bash script that runs inside the Linux guest.
    # It writes cloudgrange.crt and cloudgrange.key into the nginx_certs Docker volume
    # by running a temporary Alpine container that mounts the volume.
    #
    # AB#2347 — Defensive migration: if a previous install populated the volume with
    # server.crt/server.key (openssl defaults from a hand-deployed or pre-AB#1593 install),
    # rename them to cloudgrange.crt/cloudgrange.key before regenerating. This prevents nginx
    # from restart-looping on the "cloudgrange.crt: No such file" error.
    #
    # ESCAPING NOTE: This is a PS double-quoted here-string. Bash variables must use
    # backtick-dollar (`$VAR) to prevent PS from expanding them. PS variables ($VmIp,
    # $Hostname) are intentionally expanded here so their values are baked into the script.
    $bashScript = @"
set -euo pipefail

CERT_DIR="/tmp/cloudgrange-certs-`$`$"
mkdir -p "`$CERT_DIR"

# AB#2347: Migrate any legacy server.crt/server.key in the volume to cloudgrange.crt/cloudgrange.key
# so nginx can boot regardless of how the volume was first populated.
docker volume inspect cloudgrange_nginx_certs >/dev/null 2>&1 && docker run --rm \
    -v cloudgrange_nginx_certs:/certs \
    alpine:latest \
    sh -c '
        if [ -f /certs/server.crt ] && [ ! -f /certs/cloudgrange.crt ]; then
            echo "Migrating legacy server.crt -> cloudgrange.crt"
            mv /certs/server.crt /certs/cloudgrange.crt
        fi
        if [ -f /certs/server.key ] && [ ! -f /certs/cloudgrange.key ]; then
            echo "Migrating legacy server.key -> cloudgrange.key"
            mv /certs/server.key /certs/cloudgrange.key
        fi
        exit 0
    ' || true

# Generate openssl config with SANs
cat > "`$CERT_DIR/openssl.cnf" <<OPENSSL_EOF
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
    -keyout "`$CERT_DIR/cloudgrange.key" \
    -out    "`$CERT_DIR/cloudgrange.crt" \
    -config "`$CERT_DIR/openssl.cnf" 2>/dev/null

echo "Certificate generated."
openssl x509 -in "`$CERT_DIR/cloudgrange.crt" -noout -subject -dates 2>/dev/null

# Copy certs into the nginx_certs Docker volume via a temporary alpine container.
# The volume is named {compose_project_name}_nginx_certs; compose project = 'cloudgrange'.
docker run --rm \
    -v cloudgrange_nginx_certs:/certs \
    -v "`${CERT_DIR}:/src:ro" \
    alpine:latest \
    sh -c "cp /src/cloudgrange.crt /certs/cloudgrange.crt && cp /src/cloudgrange.key /certs/cloudgrange.key && chmod 644 /certs/cloudgrange.crt && chmod 600 /certs/cloudgrange.key"

echo "Certificates installed into nginx_certs volume."
rm -rf "`$CERT_DIR"
"@

    Write-Host "  Generating self-signed TLS certificate (RSA-2048, 3650 days, SAN: $VmIp / $Hostname)..."

    # Strip \r bytes — PS here-strings on Windows produce CRLF; bash rejects \r under set -euo pipefail.
    $bashBytes = [System.Text.Encoding]::UTF8.GetBytes($bashScript)
    $bashBytes = [byte[]]($bashBytes | Where-Object { $_ -ne 13 })

    if ($UseWsl2) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'wsl.exe'
        $psi.ArgumentList.Add('-d'); $psi.ArgumentList.Add('Ubuntu')
        $psi.ArgumentList.Add('-u'); $psi.ArgumentList.Add('root')
        $psi.ArgumentList.Add('--'); $psi.ArgumentList.Add('bash'); $psi.ArgumentList.Add('-s')
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        $p.Start() | Out-Null
        $p.StandardInput.BaseStream.Write($bashBytes, 0, $bashBytes.Length)
        $p.StandardInput.Close()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            Write-Error "New-SelfSignedCert: certificate generation failed in WSL2 (exit $($p.ExitCode))."
        }
    } elseif (-not [string]::IsNullOrEmpty($SshKeyPath)) {
        $sshOpts   = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
        $sshTarget = "cloudgrange@$VmIp"
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'ssh.exe'
        foreach ($arg in $sshOpts) { $psi.ArgumentList.Add($arg) }
        $psi.ArgumentList.Add($sshTarget)
        $psi.ArgumentList.Add('sudo')
        $psi.ArgumentList.Add('bash')
        $psi.ArgumentList.Add('-s')
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        $p.Start() | Out-Null
        $p.StandardInput.BaseStream.Write($bashBytes, 0, $bashBytes.Length)
        $p.StandardInput.Close()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            Write-Error "New-SelfSignedCert: certificate generation failed via SSH (exit $($p.ExitCode))."
        }
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudgrange' -Message 'VM credential'
        }
        $session = New-PSSession -VMName $VmName -Credential $Credential
        # Pass LF-only bytes to bash to prevent \r injection over the PSSession pipe.
        $bashScriptLf = $bashScript -replace "`r`n", "`n"
        Invoke-Command -Session $session -ScriptBlock { param($s) $s | sudo bash -s } -ArgumentList $bashScriptLf
        Remove-PSSession $session
    }

    Write-Host "  TLS certificate installed into nginx_certs volume." -ForegroundColor Green
    Write-Host "  Replace with a CA-signed certificate for production use." -ForegroundColor Yellow
}
