# Operations

## Lifecycle

| Task | Command |
| --- | --- |
| Install pinned local tools | `.\scripts\Install-Tools.ps1` |
| Generate secrets and certificates | `.\scripts\Initialize-State.ps1` |
| Start/configure JCR and mirror artifacts | `.\scripts\Prepare-Online.ps1` |
| Create isolated k3d cluster | `.\scripts\New-Cluster.ps1` |
| Install Rancher | `.\scripts\Install-Rancher.ps1` |
| Register OCI catalog and deploy applications | `.\scripts\Deploy.ps1` |
| Disconnect JCR bootstrap egress and block cluster egress | `.\scripts\Enter-AirGap.ps1` |
| Temporarily restore bootstrap egress | `.\scripts\Exit-AirGap.ps1` |
| Validate protocols and propagation | `.\scripts\Validate.ps1 -Deep` |
| Exercise restarts and persistence | `.\scripts\Test-Restart.ps1` |
| Run k6 profiles | `.\scripts\Run-LoadTests.ps1` |
| Stop the environment | `.\scripts\Teardown.ps1` |
| Destroy generated data | `.\scripts\Teardown.ps1 -PurgeData` |

JCR uses the generated administrator password for Basic Auth. JCR Edition blocks the Pro repository and user REST endpoints, so repository bootstrap uses JFrog's supported YAML configuration patch endpoint.

`Prepare-Online.ps1` mirrors the complete image set resolved by this simulation. `-IncludeRancherReleaseImageSet` additionally mirrors Rancher's full release catalog, including images for unrelated downstream Kubernetes variants and optional applications; budget hundreds of gigabytes for that mode.

## Recovery order

1. Start Docker Desktop.
2. Run `Start-Jcr.ps1` and wait for JCR health.
3. Start the k3d cluster if stopped: `k3d cluster start gscloud-airgap`.
4. Run `Validate.ps1`.

## Updating pinned components

Update `versions.lock.yaml` and the corresponding constants in `scripts/Common.ps1`, run `Prepare-Online.ps1 -ForceMirror`, then repeat the isolation and validation tests. Runtime charts must never contain references outside `jcr-proxy:8443/docker-local`.
