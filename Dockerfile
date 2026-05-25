FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

LABEL org.opencontainers.image.title="CloudSmith Installer" \
      org.opencontainers.image.description="CloudSmith platform installer for on-premises deployments" \
      org.opencontainers.image.source="https://github.com/cloudsmith-cloud/cloudsmith-installer" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /installer

COPY . .

ENTRYPOINT ["pwsh", "-File", "/installer/Install-CloudSmith.ps1"]
