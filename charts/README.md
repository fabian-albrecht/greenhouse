Greenhouse Helm Charts
----------------------

This directory provides Helm charts for the core Greenhouse platform.

The platform is installed from these independently published charts — the
`manager` and `idproxy` bootstrap charts directly (or via the kro RGD in
[`deploy/kro`](../deploy/kro)), with optional components delivered as plugins
from the default catalog. (The former `greenhouse` umbrella chart has been
retired.)

## Independently published charts

Each subdirectory here is a self-contained chart with its own `version` in its
`Chart.yaml`, published independently to GHCR as an OCI artifact at:

```
oci://ghcr.io/cloudoperators/greenhouse/charts/<chartName>
```

The `.github/workflows/helm-push.yaml` pipeline discovers every chart under
`charts/` automatically (any directory containing a `Chart.yaml`) and publishes
each one on its own — there is no hardcoded chart list and no ordering between
charts.

### Versioning & publishing

Chart version bumps are **manual** (we do not use release-please or any
auto-bump tooling):

1. When you change a chart, bump the `version` field in that chart's `Chart.yaml`
   (SemVer). The publish pipeline fails if a chart's files changed but its
   version already exists in the registry, so a bump is required to publish.
2. Keep `appVersion` lock-stepped to the operator image tag (`v*`) for charts
   that ship operator-coupled artifacts (`manager`, `idproxy`, `cors-proxy`,
   `authz`). `dashboard`/`demo` have no `appVersion`.
3. Push a tag matching `helm-chart-*.*.*` to trigger publishing. The pipeline
   packages and pushes every chart whose files changed since the previous
   publish and whose version does not yet exist in the registry.

There is **no** image build in the chart pipeline: all operator-coupled charts
reference the single operator image `ghcr.io/cloudoperators/greenhouse:<v*>`
built separately by the `v*`-tag image workflow.
