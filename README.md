# Airadio Kubernetes deployment

The public WebUI is served at `https://desktop.stream-vught.eu:8081`. Browser
code must use these **relative, same-origin** paths instead of `localhost`:

| Browser route | Internal destination |
| --- | --- |
| `/` | `airadio-webui.airadio.svc.cluster.local:8080` |
| `/api/` | `radio-api.airadio.svc.cluster.local:8080` |
| `/ws/` | `radio-api.airadio.svc.cluster.local:8080` (WebSocket upgrade) |
| `/stream/` | `radio-api.airadio.svc.cluster.local:8080` by default |

`04-webui-gateway.yaml` is the only public routing layer. It preserves the
original host and forwards WebSocket upgrade headers. The gateway and
`radio-api` use Service-DNS, never `localhost`, for pod-to-pod traffic.
Change `API_UPSTREAM`, `STREAM_UPSTREAM`, or `WEBUI_UPSTREAM` in that
deployment only when a backend is moved to another Kubernetes Service. Each
value must be a DNS name and port reachable from the gateway.

`airadio-endpoints` contains the allowed CORS origins. Both
`CORS_ALLOW_ORIGINS` (for the radio API) and `OLLAMA_ORIGINS` contain the exact
production origin and local development origins:
`https://desktop.stream-vught.eu:8081`, `http://localhost:8081`, and
`http://127.0.0.1:8081`. The radio API implementation must parse
`CORS_ALLOW_ORIGINS` as an allow-list and return the requesting origin only
when it is listed; do not replace it with `*`.

## Production deployment

The default `kustomization.yaml` applies only the infrastructure that is
actually present in this repository. It deliberately does **not** contain a
WebUI or API Deployment, so `kubectl apply -k .` cannot replace a working API
with the former `python sleep` placeholder. It also deliberately does **not**
manage the immutable `ollama-pvc` specification: it reuses the existing
`ollama-pvc` unchanged and therefore cannot fail by trying to alter its access
mode, storage class, or requested capacity.

The API and WebUI example Deployments are contracts, not deployable images.
Copy each example to a private, ignored production overlay, replace its
`registry.example.invalid/...:REPLACE_WITH_IMMUTABLE_TAG` image with the
verified immutable image digest, and adapt only its health endpoint if the
application does not expose the documented endpoint.

```powershell
# 1. Confirm the manifests are structurally valid without a cluster.
.\preflight.ps1 -Offline

# 2. Create the namespace and endpoint configuration required by the application pods.
kubectl apply -f 00-namespace.yaml
kubectl apply -f 04-webui-gateway.yaml

# 3. Apply the runtime secret individually before any rollout.
#    ICECAST_PASSWORD must exactly equal Icecast's <source-password>.
Copy-Item airadio-runtime-secrets.example.yaml airadio-runtime-secrets.yaml
# Edit airadio-runtime-secrets.yaml; never commit this file.
kubectl apply -f airadio-runtime-secrets.yaml

# 4. Create/update application Deployments from private copies of:
#    radio-api.deployment.example.yaml and airadio-webui.deployment.example.yaml
#    after replacing both example images with immutable image digests.
kubectl apply -f radio-api.deployment.production.yaml
kubectl apply -f airadio-webui.deployment.production.yaml

# 5. Create the TLS secret from the certificate and private key obtained by the operator.
kubectl -n airadio create secret tls desktop-stream-vught-eu-tls `
  --cert=desktop.stream-vught.eu.crt `
  --key=desktop.stream-vught.eu.key `
  --dry-run=client -o yaml | kubectl apply -f -

# 6. Verify prerequisites against the intended context, then reconcile all resources.
.\preflight.ps1
kubectl apply -k .
kubectl -n airadio rollout status deployment/ollama
kubectl -n airadio rollout status deployment/liquidsoap
kubectl -n airadio rollout status deployment/airadio-webui-gateway
```

The default bundle expects an existing, `Bound` `ollama-pvc`; create it with
your cluster's storage provisioning process before the first deployment. It
does not include a PVC manifest because PVC access mode, storage class, and
capacity are immutable after binding. This preserves the current
`standard`/`ReadWriteOnce` installation without a PV/PVC deletion or data
move.

For an intentional migration to the NFS storage defined by this repository,
`ollama-storage-nfs.migration.yaml` creates a **separate**
`ollama-pv-nfs`/`ollama-pvc-nfs` pair. It is excluded from the default
kustomization. Provision and bind it, copy Ollama data while Ollama is stopped,
then change `02-ollama.yaml`'s `claimName` through a reviewed private overlay
from `ollama-pvc` to `ollama-pvc-nfs` and roll out the Deployment. Keep the old
claim and PV until the migrated pod is healthy and the data is verified; this
repository deliberately provides no destructive deletion command.

The real WebUI must have label `app: airadio-webui`, listen on port `8080`,
and use only relative `/api`, `/ws`, and `/stream` URLs. The real radio API
must have label `app: radio-api`, listen on port `8080`, provide `GET
/healthz`, and honor `OLLAMA_HOST` and `CORS_ALLOW_ORIGINS`. The WebUI must
also provide `GET /`. These are hard blockers: no application image or source
exists in this repository, so they cannot be completed here.

The cluster ingress controller must be NGINX-compatible and expose its HTTPS
listener through host/NAT port `8081`. Point
`desktop.stream-vught.eu` DNS to that public address, provision the
`desktop-stream-vught-eu-tls` secret with a certificate valid for that host,
and ensure the load balancer/firewall permits TCP 8081. Port `8081` is an
external listener mapping; the Ingress itself receives HTTPS and routes by
host. Do not expose `radio-api` or `ollama` directly.

`03-liquidsoap.yaml` now reads `ICECAST_PASSWORD` only from
`airadio-runtime-secrets`; the example secret is intentionally excluded from
the kustomization and must never be committed with a real value. Its
`ICECAST_HOST` and `ICECAST_PORT` environment variables come from
`airadio-endpoints` and default to `192.168.2.5:8000`, matching the current
Icecast Docker Compose mapping `8000:8000`. The Liquidsoap 2.3 configuration
uses `environment.get` (not `getenv`) to read these process environment
values. Do not use `localhost`: Liquidsoap runs in Kubernetes and must reach
the external Icecast host address. The NFS and Icecast addresses remain
external dependencies. Move either into Kubernetes only after assigning it a
Service, then use that Service-DNS name.

The playlist source is wrapped in Liquidsoap's `mksafe`, preserving the
60-second reload behavior and normal track playback while emitting a silent
fallback when `playlist.m3u` is empty, absent, or temporarily invalid. This
prevents a missing playlist from making the source fallible and crash-looping
the pod. The Liquidsoap startup, readiness, and liveness probes therefore
check that the PID 1 Liquidsoap process is running; readiness deliberately
does not require a non-empty playlist because silent fallback audio is a
healthy, recoverable state.

If Icecast source authentication returns HTTP 401, set
`airadio-runtime-secrets.ICECAST_PASSWORD` to exactly the Icecast
`<source-password>` value; it is not the Icecast admin password. Apply the
updated manifests and restart Liquidsoap:

```powershell
kubectl apply -k .
kubectl -n airadio rollout restart deployment/liquidsoap
kubectl -n airadio rollout status deployment/liquidsoap
kubectl -n airadio logs deployment/liquidsoap --tail=100
```

`.\preflight.ps1` blocks a live rollout if the cluster's
`airadio-endpoints` ConfigMap differs from the expected
`192.168.2.5:8000`. For an intentional non-default endpoint, pass the exact
expected values as `-ExpectedIcecastHost` and `-ExpectedIcecastPort`; update
the ConfigMap in the same change.

## Operator blockers

One operator must complete each of these concrete actions before live traffic:

1. Build or obtain the actual Airadio WebUI and API images, pin their digests,
   and deploy them using the provided example contracts.
2. Supply the Icecast source password in `airadio-runtime-secrets`.
3. Provision the `desktop-stream-vught-eu-tls` TLS certificate/private key.
4. Point `desktop.stream-vught.eu` DNS to the ingress public address and map
   TCP 8081 from the host/NAT/firewall to the controller's HTTPS listener.
5. Create and bind `ollama-pvc` through the cluster's storage provisioning
   process, or complete the documented opt-in NFS migration.
6. Select the production `kubectl` context, individually apply
   `airadio-runtime-secrets.yaml`, and run `.\preflight.ps1`.

The unnumbered manifests are retained for compatibility. Deploy the resources
in `kustomization.yaml`; `ollama-storage-nfs.migration.yaml` is opt-in only.