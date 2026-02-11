# Configuring Windows Runners with Runner Scale Sets

> [!NOTE]
> Windows runner support with runner scale sets is community-maintained. GitHub does not
> officially support this configuration. If you encounter issues specific to Windows,
> the community may be able to help via [Discussions](https://github.com/actions/actions-runner-controller/discussions).

This guide explains how to configure Windows-based self-hosted runners using the
**autoscaling runner scale sets** mode of Actions Runner Controller (ARC).

## Prerequisites

- A Kubernetes cluster with **Windows nodes** (e.g., AKS with a Windows Server 2022 node pool, EKS with Windows AMIs, or GKE with a Windows node pool)
- ARC controller deployed on **Linux nodes** (the controller and listener are Linux binaries)
- A custom **Windows runner container image** (see [Building a Windows Runner Image](#building-a-windows-runner-image) below)

## How it Works

The ARC runner scale sets architecture is OS-agnostic at the controller level:

1. The **controller** and **listener** pods run on Linux nodes
2. The listener communicates with GitHub to receive job assignments
3. When a job is queued, ARC creates an **EphemeralRunner** pod
4. The runner pod is scheduled on a Windows node using `nodeSelector`
5. The runner receives its JIT config via the `ACTIONS_RUNNER_INPUT_JITCONFIG` environment variable
6. After the job completes, the runner pod is deleted (ephemeral)

```
Linux Node Pool                    Windows Node Pool
┌─────────────────────┐           ┌─────────────────────┐
│  ARC Controller     │           │  Runner Pod 1       │
│  Listener Pod       │──scales──▶│  Runner Pod 2       │
│                     │           │  ...                 │
└─────────────────────┘           └─────────────────────┘
```

## Limitations

- **`containerMode: dind` is not supported.** Docker-in-Docker requires Linux-specific
  features (`privileged` mode) that are not available in Windows containers.
- **`containerMode: kubernetes` and `kubernetes-novolume` are not supported.** The Kubernetes
  container hooks use Linux-specific paths and utilities.
- **Only the default mode (no `containerMode`) is supported for Windows runners.**
- Windows container images are significantly larger than Linux images (3–10 GB+).
  Pre-pulling images on nodes is recommended to reduce pod startup time.
- Windows containers run in **process isolation** mode by default, which shares the
  host kernel. For stronger isolation, consider Hyper-V isolation (requires compatible
  node configuration).

## Building a Windows Runner Image

You need to build a custom Windows runner container image. Below is an example
Dockerfile based on Windows Server Core 2022 LTSC:

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Install the GitHub Actions runner
ARG RUNNER_VERSION=2.321.0
WORKDIR C:\\actions-runner

RUN Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$($env:RUNNER_VERSION)/actions-runner-win-x64-$($env:RUNNER_VERSION).zip" -OutFile runner.zip; \
    Expand-Archive runner.zip -DestinationPath .; \
    Remove-Item runner.zip -Force

# Install Git (required by most workflows)
RUN Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile install-choco.ps1; \
    & .\install-choco.ps1; \
    Remove-Item install-choco.ps1 -Force; \
    choco install git.install --params "'/GitAndUnixToolsOnPath'" -y --no-progress; \
    choco install powershell-core -y --no-progress

# The entrypoint reads the JIT config from the environment variable
# that ARC injects into the runner pod.
CMD ["pwsh", "-Command", \
     "$jit = $env:ACTIONS_RUNNER_INPUT_JITCONFIG; \
      if (-not $jit) { Write-Error 'ACTIONS_RUNNER_INPUT_JITCONFIG not set'; exit 1 }; \
      Set-Location C:\\actions-runner; \
      & .\\run.cmd --jitconfig $jit"]
```

Build and push the image:

```bash
docker build -t ghcr.io/your-org/actions-runner-windows:ltsc2022 -f Dockerfile.windows .
docker push ghcr.io/your-org/actions-runner-windows:ltsc2022
```

> [!IMPORTANT]
> The Windows runner image **must** be built on a Windows host or using a Windows-capable
> build system. Cross-platform builds of Windows containers are not supported.

## Deploying Windows Runners

### 1. Install the ARC Controller (on Linux nodes)

If you haven't already installed the ARC controller:

```bash
helm install arc \
  --namespace arc-system --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

The controller runs on Linux nodes by default.

### 2. Create a Windows Runner Scale Set

Create a values file for the Windows runner configuration:

```yaml
# windows-values.yaml
githubConfigUrl: "https://github.com/your-org"
githubConfigSecret: your-github-secret

template:
  spec:
    nodeSelector:
      kubernetes.io/os: windows
    containers:
      - name: runner
        image: ghcr.io/your-org/actions-runner-windows:ltsc2022
        command: ["pwsh", "-Command"]
        args:
          - |
            $jit = $env:ACTIONS_RUNNER_INPUT_JITCONFIG
            if (-not $jit) { Write-Error 'ACTIONS_RUNNER_INPUT_JITCONFIG not set'; exit 1 }
            Set-Location C:\actions-runner
            & .\run.cmd --jitconfig $jit
    tolerations:
      - key: "node.kubernetes.io/os"
        operator: "Equal"
        value: "windows"
        effect: "NoSchedule"

# Ensure the listener (Linux binary) stays on Linux nodes
listenerTemplate:
  spec:
    nodeSelector:
      kubernetes.io/os: linux
```

Deploy the runner scale set:

```bash
helm install windows-runners \
  --namespace arc-runners --create-namespace \
  -f windows-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### 3. Use the Runners in a Workflow

Reference the runner scale set name in your workflow:

```yaml
jobs:
  build:
    runs-on: windows-runners  # matches the helm release name
    steps:
      - uses: actions/checkout@v4
      - run: Write-Host "Running on Windows!"
        shell: pwsh
```

## Troubleshooting

### Listener pod scheduled on Windows node

**Symptom:** The listener pod fails to start or crashes because it was scheduled on
a Windows node.

**Solution:** Add a `listenerTemplate` with `nodeSelector: kubernetes.io/os: linux`
to your values file, or upgrade to a version of ARC that defaults the listener to
Linux nodes.

### Runner pod stuck in ImagePullBackOff

**Symptom:** Windows runner pods are stuck pulling the image.

**Solution:** Windows container images are large. Either:
- Pre-pull the image on Windows nodes using a DaemonSet
- Use a smaller base image (e.g., `mcr.microsoft.com/windows/nanoserver:ltsc2022` — 
  but note that nanoserver has limited tool support)
- Increase the `kubelet` image pull timeout

### Runner exits immediately without picking up a job

**Symptom:** The runner pod starts and exits without running any job.

**Solution:** Verify that:
1. The `ACTIONS_RUNNER_INPUT_JITCONFIG` environment variable is set (ARC injects
   this automatically — check pod spec)
2. The runner binary version matches the expected version for your GitHub instance
3. The entrypoint correctly reads the env var and passes it to `run.cmd --jitconfig`

### containerMode validation error

**Symptom:** Helm install fails with an error about `containerMode` not being
supported with Windows.

**Solution:** Remove the `containerMode` setting from your values. Windows runners
only support the default mode (no `containerMode`).

## Additional Resources

- [ARC documentation](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller)
- [Windows containers on Kubernetes](https://kubernetes.io/docs/concepts/windows/)
- [GitHub Actions runner releases](https://github.com/actions/runner/releases)
- [Community discussion on Windows ARC support](https://github.com/orgs/community/discussions/160698)
