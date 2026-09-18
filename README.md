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

The API Deployment example remains a contract, not a deployable image. Copy
it to a private, ignored production overlay, replace its
`registry.example.invalid/...:REPLACE_WITH_IMMUTABLE_TAG` image with the
verified immutable image digest, and adapt only its health endpoint if the
application does not expose the documented endpoint. The WebUI Deployment is
included in the default bundle with its published immutable digest.

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

# 4. Create/update the API Deployment from a private copy of
#    radio-api.deployment.example.yaml after replacing its example image
#    with an immutable image digest. The WebUI ships in kustomization.yaml.
kubectl apply -f radio-api.deployment.production.yaml

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
kubectl -n airadio rollout status deployment/airadio-webui
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

The bundled WebUI has label `app: airadio-webui`, listens on container port
`3000`, and is reached by the gateway through the existing `airadio-webui`
Service on port `8080`. It runs with `WEBUI_MODE=kubernetes`, receives only
the in-cluster Liquidsoap/Icecast endpoints it requires, and uses the
namespace-scoped `airadio-webui` ServiceAccount. Its Role permits only
`get`, `patch`, and `update` on `deployments/scale` for the single
`liquidsoap` Deployment in namespace `airadio`; it cannot access other
resources or namespaces. Liquidsoap exposes its telnet control endpoint only
via the internal `liquidsoap` ClusterIP Service on port `1234`.

If the GHCR package is private, create a registry credential secret outside
this repository, then add `imagePullSecrets: [{ name:
airadio-webui-registry }]` to a reviewed private overlay for the WebUI
Deployment. Do not create or commit registry credentials here. The real radio API
must have label `app: radio-api`, listen on port `8080`, provide `GET
/healthz`, and honor `OLLAMA_HOST` and `CORS_ALLOW_ORIGINS`. The WebUI must
also provide `GET /`. The API image/source remains a hard blocker; the WebUI
image is now provided by the default bundle.

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
`airadio-endpoints` and default to the confirmed live endpoint
`192.168.2.189:8000`, matching the current Icecast Docker Compose mapping
`8000:8000`. The Liquidsoap 2.3 configuration uses `environment.get` (not
`getenv`) to read these process environment values. Do not use `localhost`:
Liquidsoap runs in Kubernetes and must reach the external host address. For a
different cluster, set `ICECAST_HOST` to that cluster's proven reachable
address and invoke preflight with the same `-ExpectedIcecastHost` value.

To diagnose this path without exposing credentials or changing a long-lived
workload, an operator can create and automatically delete a short-lived
network-check pod:

```powershell
kubectl -n airadio run icecast-network-check --rm -it --restart=Never `
  --image=busybox:1.36 -- sh -ec `
  'nc -zvw5 192.168.2.189 8000'
```

Successful TCP connection proves only routing to Icecast; it does not validate
the source password. The NFS and Icecast addresses remain external
dependencies. Move either into Kubernetes only after assigning it a Service,
then use that Service-DNS name.

### Playlist and media-library mounts

`playlist.m3u8` is read from the existing read-only NFS mount
`/volume1/radio/music` at `/radio/playlist-source`. The actual audio library is
a separate, read-only NFS volume mounted at `/radio/library`. Its source is
configured centrally in `airadio-endpoints`:

| Key | Default | Purpose |
| --- | --- | --- |
| `MEDIA_NFS_SERVER` | `192.168.2.5` | Synology NFS server |
| `MEDIA_NFS_PATH` | `/volume1/Dj/Music` | Expected export for `\\stream-vught-nl\Dj\Music` |
| `MEDIA_LIBRARY_ROOT` | `/radio/library` | In-pod library root |

Kustomize copies the first two values into the Liquidsoap NFS volume, keeping
the mount and sidecar configuration consistent. `/volume1/Dj/Music` is the
Synology-conventional translation of the confirmed Windows share; verify it on
the NAS and change `MEDIA_NFS_PATH` only if the configured NFS export differs.
The playlist normalizer only converts lines beginning with
`//stream-vught-nl/Dj/Music/` or `\\stream-vught-nl\Dj\Music\` to
`/radio/library/…`; it retains comments, URLs, and every other line unchanged.
It uses fixed `awk` prefix matching, not shell evaluation, so spaces and
non-ASCII path bytes remain unchanged. Normalizer logs report unreadable input
or conversion failures and retain the last generated playlist; Liquidsoap then
uses its silent `mksafe` fallback.

Kubernetes must mount every declared NFS volume before it starts any container.
Consequently, a missing NAS export cannot be downgraded by application code:
the Pod will remain pending with an explicit `FailedMount` event. The NAS
therefore **must** grant NFS read-only export access for `/volume1/Dj/Music`
to every Kubernetes node IP (`172.18.0.4`, `172.18.0.6`, `172.18.0.7`, and
`172.18.0.3` in the current cluster), with the export's required
root-squash/privilege settings. Verify the deployed read-only mount without
altering data:

```powershell
kubectl -n airadio exec deployment/liquidsoap -c playlist-normalizer -- `
  ls -la /radio/library
```

The command reads the existing read-only workload mount and does not reveal
credentials or alter data. Follow it with:

```powershell
kubectl -n airadio describe pod -l app=liquidsoap
kubectl -n airadio logs deployment/liquidsoap -c playlist-normalizer --tail=100
```

The playlist source is wrapped in Liquidsoap's `mksafe`, preserving the
60-second reload behavior and normal track playback from
`/radio/music/playlist.m3u8` while emitting a silent fallback when that file
is empty, absent, or temporarily invalid. This
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
`192.168.2.189:8000`, if it is a loopback address, or if the rendered
Liquidsoap configuration does not reference `/radio/playlist/playlist.m3u8`.
For an intentional non-default endpoint, pass the exact expected values as
`-ExpectedIcecastHost` and `-ExpectedIcecastPort`; update the ConfigMap in the
same change.

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