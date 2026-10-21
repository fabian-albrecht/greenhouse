---
title: "Installation"
weight: 3
---

This section provides a step-by-step guide to install Greenhouse on a Gardener shoot cluster.

Greenhouse is installed from **independently published Helm charts**. The former
`greenhouse` umbrella chart has been retired. There are two supported install
paths:

- **A. kro ResourceGraphDefinition** — a single declarative instance that rolls
  out the bootstrap charts in order. Recommended.
- **B. Direct Helm** — install the `manager` and `idproxy` charts yourself.

In both paths, the **optional components** (dashboard, cors-proxy, authz, demo)
are delivered as Greenhouse **(Cluster)Plugins** from the default catalog that
the `manager` chart ships (pointing at `cloudoperators/greenhouse-extensions`).

## Prerequisites

Before you start the installation, make sure you have the following prerequisites:

- Helm & Kubernetes CLI
- OAuth2/OpenID provider (see Authentik)
- Gardener Shoot Cluster configured to use the OIDC provider
- nginx-ingress deployed in the cluster (or a Gateway API provider — see
  `exposure.mode` below)
- cert-manager (for the manager webhook certificates)
- Flux (source-controller + helm-controller) — used to roll out plugins
- For path A only: the [kro](https://kro.run) controller

## A. Install via the kro ResourceGraphDefinition

1. Install the RGD and create an instance (see [`deploy/kro`](https://github.com/cloudoperators/greenhouse/tree/main/deploy/kro)):

    ```bash
    kubectl apply -f deploy/kro/rgd.yaml
    ```

2. Create a `Greenhouse` instance, setting your DNS domain, OIDC, and platform.
   On Gardener, set `platform: gardener` so the charts emit the Gardener
   shoot-dns-service / cert-service annotations automatically:

    ```yaml
    apiVersion: kro.run/v1alpha1
    kind: Greenhouse
    metadata:
      name: greenhouse
      namespace: greenhouse
    spec:
      dnsDomain: tld.domain      # Shoot.spec.dns.domain
      platform: gardener
      oidc:
        issuer: <issuer-url>
        clientID: <client-ID>
        clientSecret: <top-secret>
      components:
        idproxy: true
    ```

    ```bash
    kubectl apply -f my-greenhouse-instance.yaml
    kubectl get helmreleases -n greenhouse -w
    ```

   kro rolls out `manager` first (operator, CRDs, webhooks), then `idproxy`.

## B. Install via Helm directly

1. Install the **manager** (operator) chart. It also ships the default plugin
   catalog. On Gardener, use the exposure/DNS toggles to get the right ingress
   annotations:

    ```bash
    helm install greenhouse oci://ghcr.io/cloudoperators/greenhouse/charts/manager \
      --version <manager-chart-version> \
      --namespace greenhouse --create-namespace \
      --set global.dnsDomain=tld.domain \
      --set controllerManager.alerts.enabled=false   # if Prometheus CRDs are missing
    ```

2. Install the **idproxy** chart for OIDC login once the operator is up:

    ```bash
    helm install greenhouse-idproxy oci://ghcr.io/cloudoperators/greenhouse/charts/idproxy \
      --version <idproxy-chart-version> \
      --namespace greenhouse \
      --set global.dnsDomain=tld.domain \
      --set platform=gardener \
      --set oidc.issuer=<issuer-url> \
      --set oidc.clientID=<client-ID> \
      --set oidc.clientSecret=<top-secret>
    ```

   This creates the initial Greenhouse Organization and Admin Team (in the
   `greenhouse` namespace) and deploys the idproxy service handling OIDC
   authentication.

## Exposure, DNS, and platform options

The networking-facing charts (`idproxy`, `cors-proxy`, `dashboard`) expose
per-chart toggles, defaulting to the previous behavior (Kubernetes `Ingress`
with the SAP `disco` DNS annotation):

- `exposure.mode`: `ingress` (default) or `gateway` (renders a Gateway API
  `HTTPRoute` instead; set `gateway.parentRefName`).
- `dns.provider`: `disco` (default), `external-dns`, `gardener`, or `none`.
- `platform`: `generic` (default) or `gardener` (selects Gardener cert-service
  conventions).

Via the kro RGD these are set once with `spec.platform` (plus optional
`spec.exposure` / `spec.dnsProvider` overrides) and fan out to every component.

## Optional components (dashboard, authz, …)

Once the platform is up, the default catalog makes the
`cloudoperators/greenhouse-extensions` PluginDefinitions available. Deploy the
dashboard and other optional components as central-cluster Plugins (a `Plugin`
with an empty `clusterName` targets the central cluster). The dashboard chart
bundles its `cors-proxy`; disable it with `cors-proxy.enabled=false` if you
provide your own.
