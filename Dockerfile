FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

LABEL org.opencontainers.image.title="CloudGrange Installer" \
      org.opencontainers.image.description="CloudGrange platform installer for on-premises deployments" \
      org.opencontainers.image.source="https://github.com/cloudgrange-cloud/cloudgrange-installer" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /installer

COPY . .

ENTRYPOINT ["pwsh", "-File", "/installer/Install-CloudGrange.ps1"]
