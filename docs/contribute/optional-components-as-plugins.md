# Optional components as catalog plugins — follow-up (cross-repo)

Phase 4 of the chart-restructuring work moves the **optional, post-bootstrap**
Greenhouse components out of the install-time Helm charts and delivers them as
Greenhouse **(Cluster)Plugins** from the default catalog instead.

## Done in this repo

- `charts/manager` ships a **default `Catalog`** CR (toggle:
  `defaultCatalog.enabled`, default `true`) pointing at
  `cloudoperators/greenhouse-extensions`, making it the default plugin source.
  See `charts/manager/templates/catalog/default-catalog.yaml`.
- `cors-proxy` is bundled as a **subchart dependency of the `dashboard` chart**
  (`charts/dashboard/Chart.yaml`, gated by `cors-proxy.enabled`) so the dashboard
  plugin ships a single chart/release with its proxy — no cross-plugin reference
  needed. `cors-proxy` remains standalone and independently installable.

## Remaining work in `cloudoperators/greenhouse-extensions` (cannot be done here)

Add `ClusterPluginDefinition` manifests (+ published OCI charts) for the optional
components so they can be deployed as central-cluster plugins (a `Plugin` with an
empty `clusterName` targets the central/admin cluster):

- **dashboard** — references the dashboard chart (which bundles `cors-proxy`).
- **cors-proxy** — standalone, for reuse by alternative dashboards/web UIs.
- **authz** — the access-control component.
- **demo** — already `Catalog`/PluginConfig-shaped; migrate to a catalog entry.

Each `ClusterPluginDefinition.spec.helmChart` points at the published OCI chart
(`oci://ghcr.io/cloudoperators/greenhouse/charts/<name>`, or the extensions-repo
registry once charts relocate there). These definitions are imported by the
default catalog above.

## Bootstrap-tier (stays chart-installed, NOT plugin-ized)

- **manager** — the operator/CRDs/webhooks.
- **idproxy** — OIDC login; the platform is unreachable without it, so it cannot
  be delivered by the running operator (chicken-and-egg).

These are installed directly (Helm) or via the kro RGD (`deploy/kro/`).
