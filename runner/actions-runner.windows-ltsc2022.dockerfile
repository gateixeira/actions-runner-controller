# Windows runner image for Actions Runner Controller (Runner Scale Sets mode)
#
# This image runs the GitHub Actions runner agent on Windows Server Core
# and is designed for use with ARC's default mode (no containerMode).
#
# Build (must be on a Windows host):
#   docker build -t ghcr.io/your-org/actions-runner-windows:ltsc2022 -f actions-runner.windows-ltsc2022.dockerfile .
#
# Usage: see docs/windows-runner-scale-sets.md
#
# NOTE: Windows container builds require a Windows Docker host.

FROM mcr.microsoft.com/windows/servercore:ltsc2022

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG RUNNER_VERSION=2.331.0
ARG RUNNER_ARCH=x64

LABEL org.opencontainers.image.title="GitHub Actions Runner (Windows)" \
      org.opencontainers.image.description="Windows-based GitHub Actions self-hosted runner for ARC Runner Scale Sets" \
      org.opencontainers.image.source="https://github.com/actions/actions-runner-controller" \
      org.opencontainers.image.base.name="mcr.microsoft.com/windows/servercore:ltsc2022"

WORKDIR C:\\actions-runner

# Download and install the runner agent
RUN $url = \"https://github.com/actions/runner/releases/download/v${env:RUNNER_VERSION}/actions-runner-win-${env:RUNNER_ARCH}-${env:RUNNER_VERSION}.zip\"; \
    Write-Host \"Downloading runner v${env:RUNNER_VERSION}...\"; \
    Invoke-WebRequest -Uri $url -OutFile runner.zip -UseBasicParsing; \
    Write-Host 'Extracting...'; \
    Expand-Archive runner.zip -DestinationPath .; \
    Remove-Item runner.zip -Force; \
    Write-Host 'Runner installed.'

# Install Chocolatey and essential tools
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; \
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; \
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')); \
    choco install git.install --params "'/GitAndUnixToolsOnPath'" -y --no-progress; \
    choco install powershell-core -y --no-progress; \
    Write-Host 'Tools installed.'

# Entrypoint reads JIT config from the environment variable that ARC injects.
# The runner executes a single job (ephemeral) and then exits.
CMD ["pwsh", "-Command", \
     "$jit = $env:ACTIONS_RUNNER_INPUT_JITCONFIG; \
      if (-not $jit) { Write-Error 'ACTIONS_RUNNER_INPUT_JITCONFIG not set'; exit 1 }; \
      Write-Host 'Starting runner with JIT config...'; \
      Set-Location C:\\actions-runner; \
      & .\\run.cmd --jitconfig $jit; \
      $exitCode = $LASTEXITCODE; \
      Write-Host \"Runner exited with code $exitCode\"; \
      exit $exitCode"]
