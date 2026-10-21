# Greenhouse install via kro

This directory provides a [kro](https://kro.run) `ResourceGraphDefinition` (RGD)
that installs the Greenhouse **bootstrap** platform in one declarative step,
replacing the historical two-pass `helm install` of the `greenhouse` umbrella
chart.

## What it does

The RGD (`rgd.yaml`) defines a `Greenhouse` custom resource. Applying an instance
(`instance-example.yaml`) makes kro roll out, in dependency order, the
bootstrap charts via Flux:

1. **manager** — the operator, CRDs, and webhooks (everything depends on this).
2. **idproxy** — OIDC login (`dependsOn` manager).

Each component is deployed as a Flux `OCIRepository` + `HelmRelease` pointing at
the per-chart OCI artifacts published from this repo
(`oci://ghcr.io/cloudoperators/greenhouse/charts/<name>`). This reuses the Flux
machinery the operator already relies on at runtime — no new controller.

## What it does NOT do

- **Optional components** (`dashboard`, `cors-proxy`, `authz`, `demo`) are **not**
  in this graph. Once the platform is up they are delivered as Greenhouse
  (Cluster)Plugins from the default catalog (shipped by the `manager` chart,
  pointing at `cloudoperators/greenhouse-extensions`).
- **Prerequisites are not provisioned.** The target cluster must already have:
  the **kro controller**, **Flux** (source-controller + helm-controller), and
  **cert-manager** (for the manager webhook certificates).

## High-level configuration (platform default + per-axis override)

The provider options (ingress↔gateway, disco↔external-dns↔gardener DNS,
generic↔gardener) are **implemented in the charts**; the RGD only *selects* which
chart value to pass. Set one high-level field and it fans out to every component:

- `spec.platform` (`generic` | `gardener`) — derives sensible defaults for the
  exposure / DNS / cert axes.
- `spec.exposure`, `spec.dnsProvider` — optional overrides; when set they win over
  the `platform`-derived default (CEL: `has(override) ? override : derived`).

Because the axes live in the charts, a chart installed standalone (without kro)
keeps the same capability — the RGD is a convenience layer, not the source of
truth.

## Usage

```shell
# 1. Install prerequisites (kro, flux, cert-manager) — out of scope here.
# 2. Install the RGD:
kubectl apply -f deploy/kro/rgd.yaml
# 3. Create an instance:
kubectl apply -f deploy/kro/instance-example.yaml
# 4. Watch the components reconcile:
kubectl get helmreleases -n greenhouse -w
```

The legacy `greenhouse` umbrella Helm chart has been retired; new installs use
this RGD or install the `manager` + `idproxy` charts directly.
