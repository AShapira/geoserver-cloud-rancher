# Tuning workflow

The baseline uses one replica for every GeoServer Cloud service. Apply `charts/geoserver-cloud-sim/values-tuning.yaml` to use two WMS replicas:

```powershell
.\scripts\Deploy.ps1 -Tuned
```

Enable the optional WMS HPA with:

```powershell
.\scripts\Deploy.ps1 -Tuned -EnableWmsHpa
```

`Run-LoadTests.ps1` runs separate 1, 5, and 20 virtual-user profiles and writes a Markdown report under `reports/`. Compare p95 latency, failure rate, pod CPU/memory, PostgreSQL connection count, and RabbitMQ queue depth before changing resource requests, connection pools, or replica counts.
