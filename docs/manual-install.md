# Manual installation with Helm

This guide installs the sandbox without a GitOps engine: the platform's dependencies with
Helm, as the README does, then you compile the tree of [`gitops/`](../gitops) yourself
with [okdp-compiler](https://github.com/OKDP/okdp-compiler) (`okdp-compile`) and install
its instances with `helm upgrade --install`, one release at a time, in the order of their
dependencies.

The releases are the ones the GitOps install creates: same names (`<project>-<instance>`),
namespaces and values. [`gitops/`](../gitops) is okdp-compiler's tree as it is
(`platform.yaml`, `projects/<project>/instances/<instance>/`): `okdp-compile` compiles it
whole, as okdp-gitops does, each claim (a database an instance asks of the provider of
its class) bound to its provider, of whatever namespace.

- [What is installed](#what-is-installed)
- [Prerequisites](#prerequisites)
- [Step 1. Clone this repository](#step-1-clone-this-repository)
- [Step 2. Install okdp-compile](#step-2-install-okdp-compile)
- [Step 3. Prepare the working directory](#step-3-prepare-the-working-directory)
- [Step 4. Fetch the service catalogs](#step-4-fetch-the-service-catalogs)
- [Step 5. Define the helpers](#step-5-define-the-helpers)
- [Step 6. Compile every instance](#step-6-compile-every-instance)
- [Step 7. Create the kind cluster](#step-7-create-the-kind-cluster)
- [Step 8. The platform's dependencies](#step-8-the-platforms-dependencies)
- [Step 9. Operators](#step-9-operators)
- [Step 10. Secrets and RBAC](#step-10-secrets-and-rbac)
- [Step 11. The providers of the claims](#step-11-the-providers-of-the-claims)
- [Step 12. The demo project](#step-12-the-demo-project)
- [Step 13. DNS and certificate](#step-13-dns-and-certificate)
- [Using the platform](#using-the-platform)
- [Changing an instance](#changing-an-instance)
- [Cleanup](#cleanup)

## What is installed

The platform's dependencies of [`bootstrap/`](https://github.com/OKDP/sandbox-charts/tree/main/bootstrap) (cert-manager and the CA
bundle, the tools and the deletion protection, ingress-nginx, the CoreDNS patch, the
DNS server, CloudNativePG, External Secrets, Keycloak, RustFS, OpenBao, the platform's
secret store), installed with Helm as the README's step 3 does, then the instances of the platform's projects of
[`gitops/projects`](../gitops/projects), then the services of the demo project
[`gitops/projects/demo`](../gitops/projects/demo).

Forgejo and its CI runner, dependencies too, and two instances are left out, because
they only make sense with a GitOps engine:

| Left out | Why |
|---|---|
| Forgejo (sandbox-charts' `bootstrap/forgejo`) | holds the deployments repositories the engines read: nothing reads them here |
| The CI runner (sandbox-charts' `bootstrap/forgejo-runner`) | the CI of the output repository, which compiles the sources into it on a schedule |
| `okdp-system/okdp-control-plane-server`, `okdp-system/okdp-control-plane-ui` | the console commits to the deployments repositories and reads the status of the Argo CD Applications or Flux HelmReleases (`GITOPS_ENGINE` must be `argocd` or `flux`) |

There is no console. Changes are applied to the platform by editing `gitops/`, compiling
again and running Helm again (see [Changing an instance](#changing-an-instance)).

Nothing reconciles the releases either: a failed install is not retried and a manual change
on the cluster is not reverted. Each step waits for its release (`helm --wait`) before the
next one starts.

The [security notice](../README.md#security-notice) of the README applies: the sandbox ships
published demo credentials, and must not be exposed beyond localhost.

## Prerequisites

- 16 GB RAM and 4 CPUs at least for the platform; the whole demo project needs about 32 GB.
- [Docker](https://docs.docker.com/get-docker/) or a compatible container runtime,
  [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation),
  [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/),
  [Helm](https://helm.sh/docs/intro/install/) (tested with Helm 4.3.0), `git`, `curl`,
  `jq` (OpenBao's init) and [yq](https://github.com/mikefarah/yq) v4.
- Network access to the chart repositories and image registries of the upstream charts.


**Run every command in one shell**: the steps share variables and functions.

## Step 1. Clone this repository

```sh
git clone https://github.com/OKDP/okdp-sandbox.git
cd okdp-sandbox
```

## Step 2. Install okdp-compile

The tree needs an okdp-compile later than 0.6.0: the release `<project>-<instance>` of
an instance directory, the credentials of a connection read from the platform's secret
store (`secretRef.remoteKey`), the platform's TLS settings (`global.okdp.tls`), the
platform's secret store a SecretStore of each project's namespace
(`global.okdp.secrets.provider`), written with the project's manifests
(`projects/<project>/project/`).

### Install release

Download it from the [releases](https://github.com/OKDP/okdp-compiler/releases) and check
it (`version` the first release with these, later than 0.6.0):

```sh
version=<the release> os=linux arch=amd64
url=https://github.com/OKDP/okdp-compiler/releases/download/v$version
mkdir -p ~/.local/bin && cd "$(mktemp -d)"
curl -fsSLO "$url/okdp-compile_${version}_${os}_${arch}.tar.gz"
curl -fsSLO "$url/okdp-compile_${version}_checksums.txt"
sha256sum --ignore-missing -c "okdp-compile_${version}_checksums.txt"   # macOS: shasum -a 256
tar -xzf "okdp-compile_${version}_${os}_${arch}.tar.gz" -C ~/.local/bin okdp-compile
cd - >/dev/null
okdp-compile --version
```

### Compile sources (alternative)

With Go 1.27 or later, `go install github.com/okdp/okdp-compiler/cmd/okdp-compile@<ref>`
(the release, or the branch that has these features until it is released) works too. Add
`~/.local/bin` (or `$(go env GOPATH)/bin`) to your `PATH` if needed.

## Step 3. Prepare the working directory

`OKDP` is the layout, okdp-compiler's tree; `WORK` holds what the next steps fetch and
write: the catalogs, and the compiled instances, one directory per release in
`$WORK/compiled/projects/<namespace>/instances/<release>/`.

```sh
export OKDP="$PWD/gitops" WORK="$HOME/okdp-manual"
mkdir -p "$WORK/catalogs" "$WORK/compiled"
```

## Step 4. Fetch the service catalogs

An instance names a package, `catalog/<service>/<version>/` of one of the catalogs that
[`catalogs.yaml`](../gitops/catalogs.yaml) lists, at its `ref`: platform-charts,
sandbox-charts and community-charts. The contracts of the connections are the union of
the catalogs' `contracts/` directories, each catalog a repository of the tree
(`okdp-compile --repository`).

The `ref` is a commit, fetched by its hash (no branch: what `catalogs.yaml` pins is
what is installed, sandbox-charts' `bootstrap/` scripts among it):

```sh
for name in platform-charts sandbox-charts community-charts; do
  ref=$(yq -r ".repositories[] | select(.name == \"$name\") | .ref" "$OKDP/catalogs.yaml")
  git init -q "$WORK/catalogs/$name"
  git -C "$WORK/catalogs/$name" fetch -q --depth 1 "https://github.com/OKDP/$name.git" "$ref"
  git -C "$WORK/catalogs/$name" checkout -q FETCH_HEAD
done
ls "$WORK"/catalogs/*/contracts
```

If you have checkouts of the catalogs next to this repository, you can export their `ref`
instead of fetching them: replace the three `git` lines with
`mkdir -p "$WORK/catalogs/$name" && git -C "../$name" archive "$ref" | tar -x -C "$WORK/catalogs/$name"`.

## Step 5. Define the helpers

`compile` compiles the tree, the catalogs a repository each and the layout another: the
layout is okdp-compiler's tree (`platform.yaml`, the context of every instance;
`projects/<project>/project.yaml`, the context of its instances;
`projects/<project>/instances/<instance>/`, `instance.yaml` and `config.yaml`), and
okdp-compile ignores what is not (`catalogs.yaml`, `argocd/`, `flux/`, `optional/`).

The compile writes the files of okdp-compiler's Argo CD target too (`--target argocd`;
`--repo-url`, which the target requires, names no repository read here), for the
project's manifests of each namespace, `projects/<project>/project/`: its
Namespace, with the Pod Security labels of the project (`privileged` for the
platform's own projects, `global.okdp.policy.privileged` of `platform.yaml`;
`baseline` enforced for the others), and the ServiceAccount and the SecretStore
through which the namespace reads and writes the platform's secret store, OpenBao
(`secret-store.yaml`). Its Applications and the AppProjects that confine them
(`application.yaml`, `appproject.yaml`) are not used here: Helm installs every release
as you.

`install <project>/<instance>` installs or upgrades one release, `<project>-<instance>`
in the namespace `<project>`, and waits for it: the namespace and its SecretStore
first, then the compiled umbrella chart, its dependencies built in a copy of the
directory (`helm dependency build` adds `Chart.lock` and `charts/`, which the next
compile into the directory would refuse), with `instance.values.yaml` as its only
values file.

```sh
compile() {
  okdp-compile --repository "$WORK/catalogs/platform-charts" --repository "$WORK/catalogs/sandbox-charts" \
    --repository "$WORK/catalogs/community-charts" --repository "$OKDP" --target argocd \
    --repo-url http://unused.invalid/okdp.git -o "$WORK/compiled"
}

install() {
  local project="${1%%/*}" release="${1%%/*}-${1#*/}" chartdir rc compiled manifests
  compiled="$WORK/compiled/projects/$project/instances/$release"
  manifests="$WORK/compiled/projects/$project/project"
  echo "== $release"
  kubectl apply -f "$manifests/namespace.yaml"
  if [ -f "$manifests/secret-store.yaml" ]; then kubectl apply -f "$manifests/secret-store.yaml"; fi
  chartdir=$(mktemp -d)
  cp -R "$compiled/." "$chartdir"
  helm dependency build "$chartdir" &&
    helm upgrade --install "$release" "$chartdir" \
      --namespace "$project" --create-namespace --wait --timeout 15m \
      -f "$compiled/instance.values.yaml"
  rc=$?
  rm -rf "$chartdir"
  return $rc
}
```

## Step 6. Compile every instance

One compile, every instance of the tree together:

```sh
compile
```

It prints, for each claim of an instance, the provider it is bound to (the provider of
its class, the default one here, `global.okdp.provisioning` of `platform.yaml`), then,
for each instance, the instances it waits for, one line per parameter that references
another (`depends on <release> (<contract> <output>, <parameter>)`, `<namespace>/<release>`
for a provider of another namespace): the order of the install steps below follows them.

```text
demo/demo-airflow: db: claim demo.airflow.db (database-server) bound to cnpg-system/cnpg-system-cnpg-postgresql, the default class standard
demo/demo-hive: db: claim demo.hive.db (database-server) bound to cnpg-system/cnpg-system-cnpg-postgresql, the default class standard
...
demo/demo-superset: depends on demo-trino (trino trino, datasources[0].trino)
demo/demo-superset: depends on cnpg-system/cnpg-system-cnpg-postgresql (database-server demo.superset.metadatadb, metadataDb)
demo/demo-trino: depends on demo-hive (hive hive, hiveCatalogs[0].metastore)
demo/demo-trino: depends on demo-polaris (iceberg-catalog polaris, icebergCatalogs[0].catalog)
...
```

A compile that fails prints `error:` and every problem (a parameter the package refuses, a
missing connection, a claim that binds to no provider, an output no instance publishes)
and writes nothing. Fix the instance and run `compile` again.

The compiled directory of an instance holds the umbrella chart over the upstream charts
of its service (`Chart.yaml`), its values (`instance.values.yaml`), and, when the
instance has some, OKDP's own objects (`okdp.objects.yaml`, rendered by
`templates/okdp.yaml`: a claimer's `ExternalSecret`, which copies the credentials of its
claims; the `ExternalSecret` of the platform's S3 connection, which reads its
credentials from the platform's secret store; a provider's databases and
`PushSecret`s) and what it publishes (`okdp.info.yaml`: a provider's connections, one per
claim bound to it):

```sh
ls "$WORK/compiled/projects/demo/instances/demo-trino"
yq '.provides[].name' "$WORK/compiled/projects/cnpg-system/instances/cnpg-system-cnpg-postgresql/okdp.info.yaml"
```

## Step 7. Create the kind cluster

The same cluster as the README's, without the registry settings: only the images of the
control plane and of the CI runner, left out here, come from that registry.

```sh
cat > /tmp/okdp-sandbox-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: okdp-sandbox
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
    listenAddress: "127.0.0.1"
  - containerPort: 30443
    hostPort: 443
    listenAddress: "127.0.0.1"
  - containerPort: 30053
    hostPort: 30053
    listenAddress: "127.0.0.1"
    protocol: UDP
EOF
kind create cluster --config /tmp/okdp-sandbox-config.yaml
kubectl cluster-info --context kind-okdp-sandbox
```

The port mappings listen on `127.0.0.1` only: keep it that way. Ports 80 and 443 reach
ingress-nginx (installed in step 8), port 30053 the sandbox DNS server.

## Step 8. The platform's dependencies

cert-manager, trust-manager, the cluster issuer and the CA bundle, Reloader and the
deletion protection, ingress-nginx, the CoreDNS patch (`*.okdp.sandbox`
resolves to ingress-nginx inside the cluster) and the sandbox DNS server, CloudNativePG,
External Secrets, Keycloak, its database and the secrets of its realm's clients, RustFS
and the platform's access key, OpenBao and its init: the commands of sandbox-charts'
[bootstrap](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/README.md) (what the README's
[step 3](../README.md#3-install-the-platforms-dependencies) runs), but Forgejo's and its
runner's, from the catalog sandbox-charts fetched at step 4, at its `ref`. Each `helm`
waits for its release (and its hooks: Keycloak's realm, RustFS' buckets and identity).
The namespaces come first, with their Pod Security levels (`namespaces.yaml`:
`baseline` enforced, `restricted` warned and audited), which the releases'
`--create-namespace` find.

```sh
cd "$WORK/catalogs/sandbox-charts"
kubectl apply -f bootstrap/namespaces.yaml
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io --version v1.21.2 \
  -n cert-manager --create-namespace --wait -f bootstrap/cert-manager/values.yaml
helm upgrade --install trust-manager trust-manager --repo https://charts.jetstack.io --version v0.25.0 \
  -n cert-manager --create-namespace --wait -f bootstrap/trust-manager/values.yaml
helm upgrade --install cert-issuers oci://quay.io/okdp/charts/cert-issuers --version 0.2.0 \
  -n cert-manager --create-namespace --wait -f bootstrap/cert-issuers/values.yaml
kubectl apply -f bootstrap/trust-manager/bundle.yaml
helm upgrade --install reloader reloader --repo https://stakater.github.io/stakater-charts --version 2.2.17 \
  -n kube-tools --create-namespace --wait -f bootstrap/reloader/values.yaml
kubectl apply -f bootstrap/protection/policies.yaml
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --version 4.15.1 \
  -n ingress-nginx --create-namespace --wait -f bootstrap/ingress-nginx/values.yaml
bootstrap/coredns/patch.sh
helm upgrade --install dns-server coredns --repo https://coredns.github.io/helm --version 1.47.1 \
  -n dns-server --create-namespace --wait -f bootstrap/dns-server/values.yaml
helm upgrade --install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg --version 0.29.1 \
  -n cnpg-system --create-namespace --wait -f bootstrap/cloudnative-pg/values.yaml
helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets --version 2.11.0 \
  -n external-secrets --create-namespace --wait -f bootstrap/external-secrets/values.yaml
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | kubectl -n keycloak create secret generic \
  keycloak-admin --from-file=admin-password=/dev/stdin
kubectl apply -f bootstrap/keycloak/database.yaml
kubectl -n keycloak wait clusters.postgresql.cnpg.io/keycloak-db --for=condition=Ready --timeout=10m
bootstrap/keycloak/client-secrets.sh
helm upgrade --install keycloak keycloakx --repo https://codecentric.github.io/helm-charts --version 7.3.2 \
  -n keycloak --create-namespace --wait --timeout 15m \
  -f bootstrap/keycloak/values.yaml -f bootstrap/keycloak/realm.yaml
helm upgrade --install rustfs rustfs --repo https://charts.rustfs.com --version 1.0.0 \
  -n rustfs --create-namespace --wait --timeout 15m -f bootstrap/rustfs/values.yaml
helm upgrade --install openbao openbao --repo https://openbao.github.io/openbao-helm --version 0.30.4 \
  -n openbao --create-namespace --wait -f bootstrap/openbao/values.yaml
bootstrap/openbao/init.sh
cd "$OKDP/.."
```

The platform's identity of the S3 store is in the secret store, under the keys of
the namespaces of `bootstrap/openbao/s3.yaml`, `demo/s3/platform`, which the demo's
connection `platform-s3` names (no other namespace reads it; `platform/` holds no
key), and so is the secret of each client of the realm
(generated by `client-secrets.sh`, none in Git), under
`<namespace>/keycloak/<client>` of the namespaces that read it, as
`bootstrap/openbao/clients.yaml` lists them (`okdp-system/keycloak/okdp-control-plane`,
`demo/keycloak/<client>`), which the Secrets of `okdp-system/local-secrets-provider`
and `demo/secrets` read. No root token remains (`init.sh` revokes it): the names of
the keys are listed signed in as the ServiceAccount `openbao/okdp-bootstrap` (role
`okdp-bootstrap`, its token given to `bao` in the pod on its standard input, revoked
after), which lists the keys and reads none; their values are those of the
bootstrap's Secrets, the platform signs in as the ServiceAccount of each namespace:

```sh
kubectl -n openbao create token okdp-bootstrap --audience openbao --duration 10m \
  | kubectl -n openbao exec -i openbao-0 -c openbao -- sh -c \
    'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=okdp-bootstrap jwt=-)" && export BAO_TOKEN
     bao kv list okdp/; bao token revoke -self >/dev/null'
```

Check: the CA issuer is ready and the CA bundle synced:

```sh
kubectl get clusterissuers
kubectl get bundles
```

## Step 9. Operators

The Spark operator: its CRDs come first, the instances that use them after.

```sh
install spark-operator/spark-operator
```

Each `install` ends with `STATUS: deployed`. Check:

```sh
helm list -A
kubectl get pods -A
```

Every pod is `Running`. If an install fails or times out, read the events of its namespace
(`kubectl get events -n <namespace> --sort-by=.lastTimestamp`), fix the cause and run the
same `install` again: it upgrades the failed release.

## Step 10. Secrets and RBAC

The local secrets provider (the credentials of the platform's Keycloak clients, read
from the keys of its namespace in the secret store, `okdp-system/keycloak/<client>`,
into Secrets of its namespace only), and the Spark RBAC.

```sh
install okdp-system/local-secrets-provider
install default/spark-rbac
```

Check: the credentials are read:

```sh
kubectl -n okdp-system get externalsecrets
```

## Step 11. The providers of the claims

The platform's database server, the provider of the claims of databases, and the
provider of the claims of buckets on RustFS (nothing to provision while no service
claims a bucket):

```sh
install cnpg-system/cnpg-postgresql
install s3-system/s3-minio-provisioner
```

`helm --wait` does not wait for the PostgreSQL cluster itself: wait until it is healthy.

```sh
kubectl -n cnpg-system wait clusters.postgresql.cnpg.io --all --for=condition=Ready --timeout=10m
kubectl get ingress -A
```

The ingresses of Keycloak and of the S3 store are listed. The platform is up.

## Step 12. The demo project

The services of `projects/demo`, in the order of their dependencies (step 6). Their
databases are claims: a provider installed at step 11, the platform PostgreSQL,
provisions them (the compile of step 6 gave it the claims of the project), and their
credentials reach the namespace `demo` through the secret store; their object store is
the project's connection `platform-s3` (its `project.yaml`), its credentials read from
the secret store (`demo/s3/platform`).
Wait for the databases, then install the credentials of the services' sign-in:

```sh
kubectl -n cnpg-system wait databases.postgresql.cnpg.io --all --for=jsonpath='{.status.applied}'=true --timeout=5m
install demo/secrets
```

Then the services. Those with a sign-in register their OAuth client in Keycloak before
they start (the oidc-dcr Job, a Helm pre-install hook).

```sh
install demo/hive
install demo/polaris
install demo/trino
install demo/superset
install demo/airflow
install demo/jupyterhub
install demo/spark-history
```

Check the project:

```sh
helm list -n demo
kubectl get pods -n demo
```

Every release is `deployed`, every pod `Running` or `Completed`.

## Step 13. DNS and certificate

To open the services from your machine, resolve `okdp.sandbox` with the sandbox DNS server
or `/etc/hosts`: see [dns-configuration.md](dns-configuration.md).

The sandbox uses its own certificate authority, the cluster issuer of the compiled
cert-manager. Import it into your system or browser trust store to avoid warnings, and
remove it after use:

```sh
kubectl get secret default-issuer -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > okdp-sandbox-ca.crt
```

See [install-certificate.md](install-certificate.md). Otherwise, open
https://keycloak.okdp.sandbox first and accept its certificate: every service talks to
Keycloak.

## Using the platform

Sign in with Keycloak, as `adm` / `adm` (realm role `platform_admin`), or another demo user
of the realm `okdp`, [`bootstrap/keycloak/realm.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/keycloak/realm.yaml).

| Service | URL |
|---|---|
| Keycloak | https://keycloak.okdp.sandbox |
| S3 store console (user `okdp-root`, Secret `rustfs/rustfs-root`) | https://s3-console.okdp.sandbox |
| Trino | https://trino-demo.okdp.sandbox |
| Superset | https://superset-demo.okdp.sandbox |
| Airflow | https://airflow-demo.okdp.sandbox |
| JupyterHub | https://jupyterhub-demo.okdp.sandbox |
| Polaris console | https://polaris-console-demo.okdp.sandbox |
| Spark History Server | https://spark-web-proxy-demo.okdp.sandbox |

Each compiled instance that publishes something lists its URL and usage in its
`okdp.info.yaml`:

```sh
yq '.url, .usage' "$WORK/compiled/projects/demo/instances/demo-superset/okdp.info.yaml"
```

The examples of [okdp-examples](https://github.com/OKDP/okdp-examples) are an instance of
the demo project too: move `gitops/optional/projects/demo/instances/okdp-examples` to
`gitops/projects/demo/instances/`, then run `compile` and `install demo/okdp-examples`.

## Changing an instance

`gitops/` stays the source: edit the instance's `config.yaml` (or `instance.yaml`, to
change its version), compile again, and install it again, which upgrades the release:

```sh
compile
install demo/trino
```

When the change alters what the instance publishes (its outputs), install the instances
that reference it again too (step 6 lists them). A new claim, or a changed one, changes
what its provider provisions: install the provider again first.

To add a service, write its directory under `gitops/projects/demo/instances/`
([gitops/README.md](../gitops/README.md#files-written-by-people-and-by-the-console)), then
`compile`, and `install` it after the instances it references (the providers of its
claims installed again first).

To remove a release: `helm uninstall <release> --namespace <namespace>`. The objects
labelled `okdp.io/protected` (CRDs, operators) are refused deletion by the policies of
sandbox-charts' `bootstrap/protection/policies.yaml`: remove the label first.

## Cleanup

```sh
kind delete cluster --name okdp-sandbox
rm -rf "$WORK" /tmp/okdp-sandbox-config.yaml
```

If you trusted the sandbox CA, remove it too: see
[install-certificate.md](install-certificate.md#removing-the-certificate).
