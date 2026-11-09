[![Argo CD](https://img.shields.io/badge/argo%20cd-v3.4-orange.svg)](https://argo-cd.readthedocs.io/)
[![Flux](https://img.shields.io/badge/flux-v2.9-purple.svg)](https://fluxcd.io/)&ensp;&ensp;
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.30+-blue.svg)](https://kubernetes.io/)
[![Kind](https://img.shields.io/badge/kind-latest-orange.svg)](https://kind.sigs.k8s.io/)&ensp;&ensp;
[![License Apache2](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)

OKDP Sandbox is a hands-on environment for deploying, testing, and exploring the [OKDP](https://okdp.io) ecosystem on a local Kubernetes cluster.

It installs the dependencies of the platform with Helm, as a company installs its own (identity, an S3 store, the PostgreSQL operator, a secret store, a Git server), then deploys the platform (ingress, certificates, its database server), the OKDP Control Plane and a demo project on a local cluster, from a Git repository, with **Argo CD or Flux**: pick one, the repository is the same. Data services (Spark jobs, notebooks, SQL querying, dashboards) are then instantiated per project through the Control Plane, or by writing the same files in Git.

## Security notice

The sandbox is for a single workstation, not a shared or reachable environment:

- It ships **published demo credentials**: console user `adm` / `adm` and the other
  demo users of the realm `okdp` (password = user name,
  [`bootstrap/keycloak/realm.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/keycloak/realm.yaml): test fixtures to
  sign in with, not service credentials). Never reuse them, and never reuse these
  values outside the sandbox. Keycloak's admin (`admin`, of the realm `master`,
  Keycloak's administrators' only: the applications and the people are in `okdp`)
  is not one of them: its password is random, generated at the bootstrap (step 3, Secret
  `keycloak/keycloak-admin`).
- No client secret is in Git: the secret of each client of the realm is generated at
  the bootstrap (step 3, Secret `keycloak/keycloak-client-secrets`), imported into the
  realm, and written to OpenBao, the platform's secret store, under
  `<namespace>/keycloak/<client>` of the namespaces that read it (sandbox-charts'
  [`bootstrap/openbao/clients.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/openbao/clients.yaml)), where the Secrets of the instances read it
  (`okdp-system/local-secrets-provider`, `demo/secrets`): Keycloak and the services
  hold the same value, the service accounts' (`okdp-control-plane`, the console's user
  and group management; `svc-*`, `superset-trino`) among them. The services' login
  clients register by DCR; with `clientProvisioning: existing`, JupyterHub's needs one
  step ([OAuth clients](#oauth-clients-of-the-services-optional)).
- The credentials of Keycloak, Forgejo and the S3 store are generated on your cluster,
  never committed: Keycloak's admin and the secrets of the realm's clients (step 3),
  Forgejo's admin (step 3), RustFS' root and the platform's access key
  (step 3, External Secrets' generators), and the tokens of the three Forgejo
  accounts of the deployments repositories, none an admin, each with the teams of
  the repositories it needs only, none with a password anyone keeps:
  `okdp-ci`, the CI, the only pusher of the output repository's `main`, its token in
  the Actions secret of the output repository only, which Forgejo gives to its CI
  jobs only (the repositories of the sources hold no token and no workflow);
  `okdp-reader`, Argo CD's and Flux's, reads the output repository only;
  `okdp-console`, the control plane's, writes the sources only (and reads the
  output), its token in a Secret of the console's namespace only. People push with
  their own accounts, signed in through Keycloak. The repositories are private. A
  writer of the output would deploy anything, past every check of the compile: the
  console's credentials cannot.
- **What keeps the projects apart**, as on a platform:
  - the repositories, Forgejo's unit of write permission (who writes a repository
    writes every file of it): `platform.yaml` and `catalogs.yaml` in a repository
    of their own, the platform admins'; in `io`, the default, every project in one
    repository, `okdp-projects`, whose every writer writes every project, the
    platform's own among them (a small team, every member trusted with all of
    them); in `split`, a repository per project, its team's only. The output is
    the CI's alone;
  - the people's roles, from their Keycloak groups, without the console: the
    platform's administrators (`global.okdp.access.admins`, the group
    `platform_admin`) administer Argo CD and Forgejo; a project's groups (its
    `project.yaml` `access`, by default `okdp-project-<p>` editor) get that
    project's Argo CD role (its AppProject, compiled), the Forgejo team of its
    repository, and `view`, `edit` or `admin` of its namespace (RoleBindings,
    compiled; kubectl as a Keycloak user is not set up in the sandbox); Argo CD
    gives nobody else a role;
  - the secrets crossing namespaces are scoped per namespace: each namespace signs in
    to OpenBao, the platform's secret store, as its own ServiceAccount `okdp-secrets`
    (the SecretStore the compiler writes in it), and OpenBao's policy, templated on
    that namespace ([`bootstrap/openbao/init.sh`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/openbao/init.sh)), lets it
    write its own keys (`<namespace>/*`: a provider's claims, its connections' keys),
    read its claims from any provider (`+/<namespace>.*`) and the platform's keys
    (`platform/*`, written at the bootstrap: the S3 access key), nothing else. A
    Keycloak client's secret is under the keys of the namespaces that read it
    (`<namespace>/keycloak/<client>`), not the platform's. The namespace `platform`
    is reserved: nothing may run there. Nothing else copies a Secret between
    namespaces: the bootstrap installs no replicator;
  - the platform's own projects, `global.okdp.policy.privileged` of
    [`platform.yaml`](gitops/platform.yaml) (spark-operator, okdp-system), install
    cluster-scoped objects
    and write other namespaces with the engine's identity; every other project, the
    demo's and any you add, is confined to its namespace: its objects there only, no
    cluster-scoped kind, its releases installed under an AppProject of its namespace
    (Argo CD) or as a ServiceAccount of its namespace (Flux), Pod Security
    `baseline` enforced. Add a project to the list only if it must;
  - the network of a confined project's namespace is closed to the other projects:
    a NetworkPolicy the compiler writes there (`global.okdp.network` of
    [`platform.yaml`](gitops/platform.yaml), `project/network-policy.yaml`) lets in
    its own pods, the ingress controller (`ingress-nginx`), the control plane
    (`okdp-system`, the SQL editor's and the connection tests' databases) and the
    namespaces whose claims it provides (the demo's, in `cnpg-system` and
    `s3-system`), nothing else; egress stays open. The bootstrap's namespaces
    (OpenBao, Keycloak, RustFS, Forgejo) bring their own. kind's network plugin,
    kindnet, enforces them (kind 0.24 and later); with a plugin that does not, every
    pod reaches every service;
  - the CI is the output repository's: its workflow, the only one, compiles the
    sources every 2 minutes (a run whose sources did not move stops early), in an
    ephemeral container of the okdp-gitops image, on a runner registered for the
    output repository only, never a repository of the sources nor the organization
    (no other workflow can use it); the runner holds no credentials but its
    registration secret, each job gets the output repository's token. A writer of
    the sources changes what is compiled, through the compiler's checks, never the
    output itself: the sources hold no workflow and no token, their Actions off.
- **What stays sandbox-only**, never to reuse on a platform:
  - **the secret store is unsealed by itself.** OpenBao is initialized with one unseal
    key share, kept in Secret `openbao/openbao-init`, which a sidecar of its pod reads
    to unseal it at every restart: whoever reads that Secret and the volume reads
    every credential of the platform. Its root token is revoked at the init, once
    the role `okdp-bootstrap` signs in (the ServiceAccount `openbao/okdp-bootstrap`,
    which writes the keys and reads none); it serves TLS (a certificate of
    `default-issuer`). A platform's OpenBao holds its key shares elsewhere or
    auto-unseals with a KMS;
  - **the CI runner's Docker daemon is privileged** (docker-in-docker): the jobs'
    containers are not and cannot reach it, but an escape from it is root on the
    node; the namespace `forgejo` admits privileged pods. A platform runs its CI
    outside the cluster, or on a builder without privilege;
  - **the platform's S3 access key is a platform key**, `platform/s3`, which every
    namespace reads: a project could use the platform's S3 identity. A platform keeps
    a credential only one namespace needs under that namespace's keys, unreplicated,
    as the sandbox does for the realm's client secrets (`local-secrets-provider`
    reads its namespace's keys only and copies its Secrets nowhere);
  - the published credentials above.
- **Do not expose it beyond localhost.** The kind port mappings below listen on
  `127.0.0.1` only; keep it that way (no `0.0.0.0`, no port forwarding from other hosts).
- The sandbox CA can issue a certificate for any name. If you trust it (step 7),
  **remove it from your trust store after use** (see
  [install-certificate.md](docs/install-certificate.md#removing-the-certificate)).

## What is included in the sandbox?

The platform's dependencies ([`bootstrap/`](https://github.com/OKDP/sandbox-charts/tree/main/bootstrap), installed with Helm before anything compiled, step 3): OKDP neither compiles nor manages them, it reaches them through the platform's settings and connections ([`platform.yaml`](gitops/platform.yaml)).

| Dependency | Upstream chart | The platform's connection to it |
|---|---|---|
| cert-manager, trust-manager, the cluster issuer `default-issuer` (a CA minted in the cluster) and the CA bundle of every namespace | `cert-manager`, `trust-manager` (jetstack), `cert-issuers` (quay.io/okdp/charts) | `global.okdp.tls`: the issuer of every certificate, the Secret `certs-bundle` the services mount |
| ingress-nginx, on the node ports kind maps to the host | `ingress-nginx` | `global.okdp.ingress`: the class `nginx` of every ingress |
| The cluster's CoreDNS answering `*.okdp.sandbox` with the ingress controller ([`patch.sh`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/coredns/patch.sh)), the host's DNS server (node port 30053) | `coredns` | the services reach each other, Keycloak first, by their public names |
| Reloader, the deletion protection ([`policies.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/protection/policies.yaml)) | `reloader` | workloads restarted when their Secrets change, `okdp.io/protected` objects and the operators' CRDs not deleted |
| CloudNativePG, the PostgreSQL operator | `cloudnative-pg` | the platform's database server (`cnpg-system/cnpg-postgresql`) runs on it |
| External Secrets | `external-secrets` | the SecretStore the compiler writes in each project's namespace, over the secret store |
| OpenBao, the platform's secret store, over https (a certificate of `default-issuer`): its KV mount `okdp`, the Kubernetes auth (the role `okdp`, of the audience `openbao`) and the policy of the namespaces, the platform's keys | `openbao` | `global.okdp.secrets`: what crosses namespaces (the S3 access key, the secrets of Keycloak's clients, the claims' credentials), each namespace its own keys; each namespace's SecretStore checks OpenBao's certificate against `certs-bundle` and signs in with a token of the audience `openbao` |
| Keycloak, its PostgreSQL and its realm `okdp` (users, roles, clients and their secrets, generated; the services register their clients with initial access tokens, no anonymous registration; `master` for Keycloak's admin only) | `keycloakx` (codecentric) | `global.okdp.oidc`; its clients' secrets in the secret store, under the keys of the namespaces that read them (`<namespace>/keycloak/<client>`) |
| RustFS, the S3 store, its buckets and the platform's access key | `rustfs` | the connection `platform-s3` (contract `s3`), its credentials in the secret store (`platform/s3`) |
| Forgejo, the deployments repositories and the service catalogs | `forgejo` | the control plane server's settings |
| The CI runner of the deployments repositories, each compile a container of the okdp-gitops image on its Docker daemon | [`forgejo-runner`](https://github.com/OKDP/sandbox-charts/tree/main/bootstrap/forgejo-runner) (this repository's chart) | registered by `scripts/configure.sh --push` for the output repository only |
| Argo CD or Flux (step 5) | | the entry point [`gitops/argocd`](gitops/argocd) or [`gitops/flux`](gitops/flux) |

The platform ([`gitops/projects`](gitops/projects), compiled): its own services are instances of projects without user members, one namespace each, `projects/<namespace>/instances/<name>/`; no layers, the instances that wait for others (references, claims) are ordered by the engine, the others retried until the CRDs of their operator exist. The projects that install cluster-scoped objects or write other namespaces are the platform's own, listed in `global.okdp.policy.privileged` of [`platform.yaml`](gitops/platform.yaml) (spark-operator, okdp-system); every other project, the demo's and the platform's that need no more (cnpg-system, s3-system, default), is confined to its namespace.

| Project (namespace) | Instances |
|---|---|
| `spark-operator`, `default` | the Spark operator, the Spark RBAC |
| `cnpg-system` | the platform's database server (a CloudNativePG cluster, the provider of the services' databases) |
| `s3-system` | the provider of the services' buckets on the S3 store of the bootstrap (RustFS, through MinIO's admin API: a bucket, a policy and a user per claim) |
| `okdp-system` | OKDP Control Plane server and UI, the local secrets provider |

The bootstrap's cert-manager and ingress-nginx can be replaced by the cluster's own: the platform and the dependencies name them by the platform's settings only, the ingress class (`global.okdp.ingress.className`), the cluster issuer (`global.okdp.tls.clusterIssuer`) and the Secret of the CA bundle (`global.okdp.tls.caBundleSecret`, which a cluster's own trust distribution can provide).

The demo project ([`gitops/projects/demo`](gitops/projects/demo)): the data services Hive Metastore, Polaris, Trino, Superset, Airflow, JupyterHub and Spark History Server, wired together by the outputs they publish, their databases claimed of the platform's database server, their object store the platform's S3 connection.

Optional ([`gitops/optional`](gitops/optional)): the operators of the community services, and the [okdp-examples](https://github.com/OKDP/okdp-examples) medallion lakehouse seed for the demo project. Keycloak, RustFS and OpenBao, the platform's identity provider, S3 store and secret store, are installed with Helm by the bootstrap, as dependencies, not packages of a catalog; the catalog sandbox-charts offers SeaweedFS as a package, to deploy as an OKDP instance (a project's own S3 store, for instance).

## How it works

```
helm (step 3) ─► the platform's dependencies: cert-manager, ingress-nginx, the DNS, the tools, CloudNativePG,
                 External Secrets, Keycloak, the S3 store, OpenBao, Forgejo and its CI runner
                 (reached through the platform's settings and connections, never compiled)

basic user ─► console UI ─► control-plane server ─(git commit)─┐
GitOps user ────────────────────────────(git commit / PR)────► the tree: platform.yaml, projects/ (Forgejo)
                                                               │ every 2 min: the output's CI (Forgejo Actions)
   service catalogs (Git) ─► packages ─► okdp-gitops compile (okdp-compiler), runner forgejo-runner
                                                               ▼
         output: compiled/ (one umbrella chart and values file per instance, the engines' files), argocd/
                  Argo CD: Application (path + values file) │ Flux: HelmRelease (chart from Git)
                                                               ▼
                    Helm installs the SAME umbrella chart with the SAME compiled values
```

- Every service of the platform and of the projects is an instance of a package of the service catalogs with its values in Git, `projects/<project>/instances/<instance>/` of okdp-compiler's tree: [`gitops/`](gitops) is the initial deployments layout, the tree and the entry points of the engines. Its [README](gitops/README.md) specifies every file.
- Git, on the in-cluster Forgejo, is the only desired state. The console commits the tree there; so can you, a plain commit. The tree is compiled whole ([okdp-compiler](https://github.com/OKDP/okdp-compiler)), each instance into an umbrella chart over the upstream charts of its service and the one values file it is installed with, with the Argo CD and Flux files of its targets, `compiled/` of the output repository, by [okdp-gitops](https://github.com/OKDP/okdp-gitops), the Git around the compiler: by the CI of the output repository every 2 minutes (its workflow `.forgejo/workflows/okdp-gitops.yaml`, the only one, on a schedule, run by the Forgejo Actions runner [`forgejo-runner`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/forgejo-runner/values.yaml) of the bootstrap; a run whose sources did not move stops early), and by `scripts/configure.sh --push` for the layout of this repository, which it pushes compiled. A push that does not compile writes nothing: the engine keeps deploying the last output. Argo CD or Flux deploys `compiled/`. This repository holds no compiled file: only what bootstraps the sandbox.
- On Forgejo, the layout lives in a platform repository (the platform admins'), a projects repository and an output repository (`io`, the default, for a small team whose every member is trusted with every project), or in a platform repository, one repository per project and an output repository (`split`, a team per project): the **topology**, chosen with `scripts/configure.sh` ([Topologies](gitops/README.md#topologies), who can do what). The output is always in a repository of its own, which the CI alone writes; Argo CD and Flux read it only.
- The packages come from Git, not from a chart registry: the catalogs [platform-charts](https://github.com/OKDP/platform-charts), [sandbox-charts](https://github.com/OKDP/sandbox-charts) and [community-charts](https://github.com/OKDP/community-charts) (`catalog/<service>/<version>/`, one directory per package version, and the contracts of the connections), copied to the in-cluster Forgejo, where the control plane server reads them ([Service catalogs](gitops/README.md#service-catalogs)). The upstream charts come from their own repositories.
- The platform's dependencies are not compiled: cert-manager, ingress-nginx, the DNS, the tools, CloudNativePG, External Secrets, Keycloak, the S3 store, OpenBao, Forgejo and its CI runner, and the engine, are installed with Helm first ([`bootstrap/`](https://github.com/OKDP/sandbox-charts/tree/main/bootstrap), step 3), and the compiled tree reaches them through the platform's settings (`global.okdp.oidc`, `global.okdp.secrets`) and connections: the S3 store is the platform connection `platform-s3` (`connections` of [`platform.yaml`](gitops/platform.yaml)), its endpoints and bucket, its credentials a key of the platform's secret store (`platform/s3`), which the compiler reads into each instance's namespace; Keycloak is `global.okdp.oidc`, and its clients' secrets, generated at the bootstrap, keys of the store too, under the keys of the namespaces that read them (`<namespace>/keycloak/<client>`), which `local-secrets-provider` reads into the Secrets of the services. Any S3-compatible store OKDP does not manage takes its place the same way.
- The databases of the services are **claims**: a service asks for a database of its own, and the platform's database server (`cnpg-system/cnpg-postgresql`), the provider of the platform's class (`global.okdp.provisioning` of [`platform.yaml`](gitops/platform.yaml)), creates it and publishes its connection, its credentials crossing namespaces through the platform's secret store ([Claims](gitops/README.md#claims)). A project may declare named claims too, shared by its services (`claims` of its `project.yaml`). A service may claim a bucket the same way (`{}` in place of an `s3` connection's name): the provider of the platform's class, `s3-system/s3-minio-provisioner`, creates it on the S3 store of the bootstrap, with an identity limited to it, through MinIO's admin API, as the provisioning identity the bootstrap generates (a key of `s3-system` in OpenBao). No service of the sandbox claims one: they name the platform's connection `platform-s3`.
- The secret store, OpenBao, keeps the namespaces apart: the compiler writes in each project's namespace a ServiceAccount and a SecretStore of External Secrets that signs in to OpenBao as that ServiceAccount (`global.okdp.secrets.provider`), and OpenBao's policy, templated on the namespace, lets a namespace write its own keys (`<namespace>/*`, a provider's claims), read its claims from any provider (`+/<namespace>.*`) and the platform's keys (`platform/*`), nothing else ([`bootstrap/openbao/init.sh`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/openbao/init.sh)). A Vault or a cloud secret manager takes OpenBao's place with the same policy and its own provider in `platform.yaml`.

| Concern | Owner |
|---|---|
| Catalog of the OKDP services and control plane packages | [`OKDP/platform-charts`](https://github.com/OKDP/platform-charts) |
| Compiler of the instances (service definitions in YAML + CEL) | [`OKDP/okdp-compiler`](https://github.com/OKDP/okdp-compiler) |
| Compile of the whole layout, the Argo CD and Flux files, the CI of the sources | [`OKDP/okdp-gitops`](https://github.com/OKDP/okdp-gitops) |
| Contract schemas of the connections | the catalogs, `contracts/` |
| Catalog of the sandbox's platform packages (the provider of the claims of databases) and of optional ones (Keycloak, SeaweedFS, RustFS) | [`OKDP/sandbox-charts`](https://github.com/OKDP/sandbox-charts) |
| Catalog of the community services (Ollama, DuckDB, Hop, NiFi, Strimzi, K8ssandra) | [`OKDP/community-charts`](https://github.com/OKDP/community-charts) |
| Notebooks, DAGs, and runnable examples | [`OKDP/okdp-examples`](https://github.com/OKDP/okdp-examples) |
| Control Plane web UI | [`OKDP/okdp-control-plane-ui`](https://github.com/OKDP/okdp-control-plane-ui) |
| Control Plane backend server (API) | [`OKDP/okdp-control-plane-server`](https://github.com/OKDP/okdp-control-plane-server) |
| Sandbox bootstrap: the scripts that install the platform's dependencies (Helm) and the initial deployments layout (this repository) | `OKDP/okdp-sandbox` |
| The platform's dependencies: their values, manifests and init scripts (`bootstrap/`), and the sandbox's packages | `OKDP/sandbox-charts` |

## Prerequisites

- 16 GB RAM and 4 CPUs at least for the platform; the whole demo project needs about 32 GB.
- [Docker](https://docs.docker.com/get-docker/) or a compatible container runtime, [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/), [Helm](https://helm.sh/docs/intro/install/) (3.8 or later) and `git`.
- For Argo CD: nothing more (tested with v3.4.2). For Flux: the [Flux CLI](https://fluxcd.io/flux/installation/) (tested with v2.9.5).
- For step 3, `scripts/bootstrap.sh`: [yq](https://github.com/mikefarah/yq) v4, `jq` (the CoreDNS patch, OpenBao's init), `awk` and `git` (sandbox-charts, where the bootstrap lives).
- To configure the sandbox and change the layout by hand: `okdp-gitops` ([okdp-gitops](https://github.com/OKDP/okdp-gitops), `make build`), [yq](https://github.com/mikefarah/yq) v4, `curl` and `jq`. The scripts read the service catalogs from checkouts of [platform-charts](https://github.com/OKDP/platform-charts), [sandbox-charts](https://github.com/OKDP/sandbox-charts) and [community-charts](https://github.com/OKDP/community-charts) next to this repository when there are some (at the ref [`catalogs.yaml`](gitops/catalogs.yaml) names), else from GitHub.

## Quick start

The steps below install the sandbox with a GitOps engine. To install it with Helm only,
without Argo CD, Flux, Forgejo or the console, see [manual-install.md](docs/manual-install.md).

### 1. Clone this repository

```sh
git clone https://github.com/OKDP/okdp-sandbox.git
cd okdp-sandbox
```

The service catalogs, sandbox-charts' bootstrap among them (step 3), are read from
checkouts next to this one when there are (`../platform-charts`, `../sandbox-charts`,
`../community-charts`, at the `ref` of [`gitops/catalogs.yaml`](gitops/catalogs.yaml)),
else from GitHub.

### 2. Create the kind cluster

```sh
cat > /tmp/okdp-sandbox-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: okdp-sandbox
# TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
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
# TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
# The control plane images come from repo.alliage.io:8082, over plain HTTP.
docker exec okdp-sandbox-control-plane mkdir -p /etc/containerd/certs.d/repo.alliage.io:8082
docker exec -i okdp-sandbox-control-plane tee /etc/containerd/certs.d/repo.alliage.io:8082/hosts.toml >/dev/null <<EOF
server = "http://repo.alliage.io:8082"
[host."http://repo.alliage.io:8082"]
  capabilities = ["pull", "resolve"]
EOF
```

<details>
<summary><strong><small>PowerShell</small></strong></summary>
<br>

```powershell
@"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: okdp-sandbox
# TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
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
    hostPort: 53
    listenAddress: "127.0.0.1"
    protocol: UDP
"@ | Out-File -FilePath "$env:TEMP\okdp-sandbox-config.yaml" -Encoding UTF8
kind create cluster --config "$env:TEMP\okdp-sandbox-config.yaml"
# TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
# The control plane images come from repo.alliage.io:8082, over plain HTTP.
docker exec okdp-sandbox-control-plane mkdir -p /etc/containerd/certs.d/repo.alliage.io:8082
@"
server = "http://repo.alliage.io:8082"
[host."http://repo.alliage.io:8082"]
  capabilities = ["pull", "resolve"]
"@ | docker exec -i okdp-sandbox-control-plane tee /etc/containerd/certs.d/repo.alliage.io:8082/hosts.toml
```

</details>

The CI's jobs run in containers of the okdp-gitops image, which the runner's own Docker
daemon pulls (docker-in-docker): an image loaded into the node (`kind load`) is not seen
there, it comes from a registry. No okdp-gitops image is published yet
(TODO(okdp-gitops)): build it from checkouts of
[okdp-gitops](https://github.com/OKDP/okdp-gitops) and
[okdp-compiler](https://github.com/OKDP/okdp-compiler) next to this repository, and serve
it from a registry of your own on the kind network, `okdp-registry:5000` from the
cluster (plain HTTP), `127.0.0.1:5001` from your machine; the node's containerd pulls
from it too (the control plane images may be pushed there instead of `kind load`):

```sh
docker run -d --restart=always --name okdp-registry --network kind -p 127.0.0.1:5001:5000 registry:2
docker build --build-context okdp-compiler=../okdp-compiler -t 127.0.0.1:5001/okdp-gitops:dev ../okdp-gitops
docker push 127.0.0.1:5001/okdp-gitops:dev
docker exec okdp-sandbox-control-plane mkdir -p /etc/containerd/certs.d/okdp-registry:5000
docker exec -i okdp-sandbox-control-plane tee /etc/containerd/certs.d/okdp-registry:5000/hosts.toml >/dev/null <<EOF
server = "http://okdp-registry:5000"
[host."http://okdp-registry:5000"]
  capabilities = ["pull", "resolve"]
EOF
```

The CI runner's values, sandbox-charts'
[`bootstrap/forgejo-runner/values.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/forgejo-runner/values.yaml),
name it by default; the runner's NetworkPolicy lets its pod out to that registry
(`networkPolicy.registries`, the kind network `172.18.0.0/16` on port 5000), the
cluster's DNS, Forgejo and the internet's port 443, no private range. An image of
another registry is set there, in the checkout next to this repository (step 3 with
`--dir ../sandbox-charts/bootstrap`), its registry's address and port added to
`networkPolicy.registries` when it is on a private range or another port
(`scripts/e2e-kind.sh` does the same with `E2E_GITOPS_IMAGE`, the address of the
registry's host, or `E2E_GITOPS_REGISTRY_CIDR`):

```yaml
okdpGitopsImage:
  repository: okdp-registry:5000/okdp-gitops
  tag: dev
insecureRegistries: [okdp-registry:5000]
networkPolicy:
  registries:
    - {cidr: 172.18.0.0/16, port: 5000}
```

The console shows pod CPU and memory through metrics-server:

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"},
       {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/timeoutSeconds", "value": 3},
       {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/timeoutSeconds", "value": 3}]'
```

> The default probe timeout of 1s is too tight for a single-node kind cluster: under
> load the probes fail and the pod is restarted with a new IP.

### 3. Install the platform's dependencies

cert-manager, ingress-nginx, the DNS, the tools, CloudNativePG, External Secrets,
Keycloak, the S3 store, OpenBao, Forgejo and its CI runner are the prerequisites of the
platform: installed with Helm before anything compiled, from the bootstrap of the
catalog sandbox-charts, [`bootstrap/`](https://github.com/OKDP/sandbox-charts/tree/main/bootstrap): their values,
manifests and init scripts, and [`charts.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/charts.yaml),
the charts and versions, in the order installed. Its
[README](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/README.md) lists each command and what it
installs. The compiled platform reaches them through its settings and connections;
nothing of them is in the deployments repositories, and the engine does not manage
them: upgrade one by running its command again, or the whole script.

```sh
scripts/bootstrap.sh
```

[`scripts/bootstrap.sh`](scripts/bootstrap.sh) reads `bootstrap/` as the catalogs are
read ([`gitops/catalogs.yaml`](gitops/catalogs.yaml): sandbox-charts at its `ref`, from
the checkout next to this repository, else GitHub; `--catalog sandbox-charts=SRC` or
`OKDP_CATALOGS` for another), so that the prerequisites and the packages are of one
commit. `--dir DIR` installs a bootstrap directory as it is, uncommitted changes
included (`--dir ../sandbox-charts/bootstrap`). It applies the namespaces first,
with their Pod Security levels (`bootstrap/namespaces.yaml`: `baseline` enforced,
`restricted` warned and audited, `forgejo` alone `privileged` for the CI runner's
Docker daemon), which the releases' `--create-namespace` find. It needs `helm`, `yq`,
`jq`, `awk` and `git`.

Their ingresses (`keycloak`, `s3`, `s3-console`, `forgejo` `.okdp.sandbox`) are served
by the ingress controller installed first. The
Keycloak admin's password, for its admin console (user `admin`):
`kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.admin-password}' | base64 -d`;
the Forgejo admin's password, for its web UI:
`kubectl -n forgejo get secret okdp-forgejo-admin -o jsonpath='{.data.password}' | base64 -d`;
RustFS' root, for its console:
`kubectl -n rustfs get secret rustfs-root -o jsonpath='{.data.RUSTFS_SECRET_KEY}' | base64 -d`
(user `okdp-root`); a client's secret:
`kubectl -n keycloak get secret keycloak-client-secrets -o jsonpath='{.data.<client>}' | base64 -d`;
the names of OpenBao's keys, signed in as the ServiceAccount `openbao/okdp-bootstrap`
(role `okdp-bootstrap`; its token given to `bao` in the pod on its standard input,
revoked after): no root token remains, the bootstrap's init revokes it, and that
identity lists the keys and reads none (their values are those of the Secrets above;
the platform signs in as the ServiceAccount of each namespace):

```sh
kubectl -n openbao create token okdp-bootstrap --audience openbao --duration 10m \
  | kubectl -n openbao exec -i openbao-0 -c openbao -- sh -c \
    'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=okdp-bootstrap jwt=-)" && export BAO_TOKEN
     bao kv list okdp/; bao token revoke -self >/dev/null'
```

A sandbox installed before the dependencies left the compiled tree is reinstalled:
delete the cluster ([Cleanup](#cleanup)) and start again.

### 4. Put the repositories on Forgejo

Choose the GitOps engine and the topology of the repositories before pushing (Argo CD
and `io` as committed); the script only edits the layout, run it without arguments
to be asked:

```sh
scripts/configure.sh --engine argocd --topology split   # or: scripts/configure.sh -i
git add -A gitops && git commit -m "chore: configure the sandbox"
```

| Topology | Repositories (organization `okdp`) | For |
|---|---|---|
| `io` | `okdp-platform` (`platform.yaml`, `catalogs.yaml`: the platform admins), `okdp-projects` (`projects/`) and `okdp-output` (`compiled/`, `argocd/`: the CI alone) | a small team: every writer of `okdp-projects` writes every project, the platform's own among them |
| `split` | `okdp-platform` (`platform.yaml`, `catalogs.yaml`, `projects.yaml`), one `okdp-project-<p>` per project (the platform's among them), and `okdp-output` | bigger deployments: a team writes its project's repository only |

The output is always in a repository of its own, which the CI's account alone pushes
to: there is no topology of one repository (the former `mono`), whose every writer
could deploy anything past the compiler's checks
([Topologies](gitops/README.md#topologies), who can do what).

Then compile the committed layout and put it on Forgejo, with the service catalogs
`okdp/platform-charts`, `okdp/sandbox-charts` and `okdp/community-charts` (nothing is
pushed when the layout does not compile; `scripts/compile.sh` shows the problems). The
repositories are private. The script puts the CI in the output repository only
(`.forgejo/workflows/okdp-gitops.yaml`, `okdp-gitops workflow --for output`, the
topology in it), turns its Actions on (off in the repositories of the sources, which
hold no workflow and no secret) and registers its runner,
[`forgejo-runner`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/forgejo-runner/values.yaml) of the bootstrap, in
Forgejo, for the output repository only, never a repository of the sources nor the
organization (the runner's pod starts then): every 2 minutes, and when dispatched
(the **Actions** tab of the output repository), a run compiles the latest sources
into the output repository, a new container of the okdp-gitops image on the runner's
own Docker daemon; a run whose sources did not move since the last compile
(`sources.yaml` of the output) stops early. Forgejo runs the schedules of its Actions
([`bootstrap/forgejo`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/forgejo/values.yaml), `cron.start_schedule_tasks`).
The script gives each writer and reader its own Forgejo account, none an admin,
member of the teams of the repositories it needs only (an older sandbox's single
account `okdp-gitops` is deleted, its tokens and teams with it):

| Account | Writes | Reads | Its token, where |
|---|---|---|---|
| `okdp-ci`, the CI | the output repository (the only pusher of its `main`) | the sources and the catalogs (split: every repository of `okdp`, so that a project the console creates is compiled at the next run) | `write:repository`, the Actions secret `OKDP_GITOPS_TOKEN` of the output repository only |
| `okdp-reader`, Argo CD and Flux | nothing | the output repository only | `read:repository`, Secrets `argocd/okdp-gitops-reader` (a repository credential of the output's exact URL) and `flux-system/okdp-gitops-reader` |
| `okdp-console`, the control plane (when the layout installs it) | the sources (split: may create a new project's repository) | the output (the compiled tree it shows) and the catalogs | `write:repository`, Secret `okdp-system/okdp-console-git` (`gitops.credentialsSecret`: user name and token, no password); split, `write:organization`, Secret `okdp-system/okdp-forgejo-token` |

Each run sets a random password on each account, creates its tokens with it and
forgets it; their previous tokens are deleted. The CI's jobs get the CI's token from
the output repository's Actions secret (the runner holds no git credentials; the
token goes in clear, over `http://`, to the in-cluster Forgejo only, its exact host,
never a glob of the cluster's Services: the workflow carries
`GITOPS_INSECURE_HTTP_HOSTS=forgejo-http.forgejo.svc.cluster.local`,
`CI_INSECURE_HTTP_HOSTS` of `scripts/lib/topology.sh`, with which `scripts/check.sh`
has `okdp-gitops workflow` write the CI's workflow, refused for another `http://`
host; not `https://forgejo.okdp.sandbox`, which the job's container, without the
platform's CA bundle, cannot check), and
the runner's registration secret to `forgejo/okdp-runner-registration`, nowhere else.
The output repository's `main` is protected: `okdp-ci` alone pushes there (its
push whitelist), never the admin, the console nor a person, no force push; the
script pushes the sources as the admin and the output as `okdp-ci`. A repository the
console creates for a new project (`split`) gets no workflow, no secret and no
runner: the next run of the output's CI compiles it. It
reaches Forgejo through a `kubectl port-forward` of the current context, as the admin
of Secret `forgejo/okdp-forgejo-admin`; `--dry-run` shows what it would do:

```sh
scripts/configure.sh --push
```

Then choose **one** engine (Argo CD and Flux read the output repository).

### 5a. Install with Argo CD

```sh
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/install.yaml
# The health of Applications (the sync waves wait for healthy Applications), the sign-in
# with Keycloak and its roles. Keycloak's certificate is checked against the platform's
# CA bundle, which trust-manager writes in the new namespace (Secret certs-bundle):
# rootCA of oidc.config, added to the patch here.
until kubectl -n argocd get secret certs-bundle >/dev/null 2>&1; do sleep 2; done
ca="$(mktemp)"
kubectl -n argocd get secret certs-bundle -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
CA_FILE="$ca" yq '.data["oidc.config"] |= (from_yaml | .rootCA = load_str(strenv(CA_FILE)) | to_yaml)' \
  gitops/argocd/bootstrap/argocd-cm-patch.yaml \
  | kubectl -n argocd patch configmap argocd-cm --type merge --patch-file /dev/stdin
rm -f "$ca"
kubectl -n argocd patch configmap argocd-rbac-cm --type merge \
  --patch-file gitops/argocd/bootstrap/argocd-rbac-cm-patch.yaml
# argocd-server reads the OIDC settings at startup only.
kubectl -n argocd rollout restart deployment argocd-server
kubectl apply -n argocd -f gitops/argocd/
```

Follow the Applications (one per instance):

```sh
kubectl -n argocd get applications --watch
```

The Argo CD UI is at https://argocd.okdp.sandbox, through the bootstrap's ingress-nginx
([`gitops/argocd/ingress.yaml`](gitops/argocd/ingress.yaml)): **Log in via Keycloak** with a
demo user (`adm` and `alice`, of the group `platform_admin`, are admins; `bob`, `mark`,
`nina` and `grace`, of the group `okdp-project-demo`, the editors of the project `demo`:
they see and sync its Applications only; a user of no group sees nothing), or user
`admin`, password in secret `argocd/argocd-initial-admin-secret`.

### 5b. Install with Flux

The console's engine must be `flux` first (`scripts/configure.sh --engine flux`,
which sets `gitops.engine` in
[`okdp-control-plane-server/config.yaml`](gitops/projects/okdp-system/instances/okdp-control-plane-server/config.yaml));
commit and push it to Forgejo as above (`configure.sh --push`). Then:

```sh
flux install --components=source-controller,kustomize-controller,helm-controller
# The chart version must not carry the OCI digest (see gitops/README.md).
# Cross-namespace source references disabled and default service account locked
# down: a project's release cannot reference another namespace's sources, and a
# release without an explicit service account gets no permissions.
kubectl -n flux-system patch deployment helm-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"},
       {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--no-cross-namespace-refs=true"},
       {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-service-account=okdp-none"}]'
kubectl -n flux-system patch deployment kustomize-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--no-cross-namespace-refs=true"},
       {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-service-account=okdp-none"}]'
kubectl apply -f gitops/flux/sync.yaml
```

Follow the HelmReleases, one per instance:

```sh
flux get kustomizations --watch
flux get helmreleases -n okdp-releases
```

Either way, nothing else is applied by hand: the engine deploys every instance, those
that wait for others after them (Argo CD's sync waves, Flux's `dependsOn`), the others
retried until the platform they need is up. Everything is ready after 15 to 30 minutes,
depending on the machine and the network.

Then turn on Forgejo's sign-in with Keycloak, once: restart Forgejo (it checks Keycloak's
certificate against the sandbox CA bundle, `SSL_CERT_DIR`, which it reads at startup, and
the platform creates the bundle after Forgejo's bootstrap; an OAuth source has no setting
that skips the check), then
push again with `--sign-in`, which creates its OAuth source (in Forgejo's database: the
chart would recreate it at every start, which then needs Keycloak reachable), with the
secret of the realm's client `forgejo` (step 3), given to the pod on its standard input,
and the map of the Keycloak groups to the teams: the platform's administrators
(`global.okdp.access.admins` of [`gitops/platform.yaml`](gitops/platform.yaml), the
group `platform_admin`) are Forgejo's administrators and the organization's owners;
the groups of each project's roles (its `project.yaml` `access`, by default
`okdp-project-<p>` editor) a team `okdp-project-<p>` that writes the project's
repository (split `okdp-project-<p>`; io `okdp-projects`, every project's), the
viewers a team `okdp-project-<p>-viewers` that reads it; nobody writes the platform's
repository but its owners, nor the output but `okdp-ci`. Each later `--push` updates
the map:

```sh
kubectl -n forgejo rollout restart deployment forgejo
kubectl -n forgejo rollout status deployment forgejo
scripts/configure.sh --push --sign-in
```

A person's teams follow their groups at each sign-in. kubectl as a Keycloak user is
not set up: kind's API server authenticates no OIDC user (no `--oidc-issuer-url`),
so the RoleBindings the compiler writes for the projects' groups (`view`, `edit`,
`admin` of their namespace, `global.okdp.access.groupPrefix` empty) wait for an API
server that does.

### Proxy (optional)

If the cluster reaches the Internet through a proxy, set it on the engine's controllers
(Argo CD: `kubectl -n argocd set env deploy argocd-repo-server HTTPS_PROXY=… NO_PROXY=…`;
Flux: the same on `-n flux-system deploy -l app.kubernetes.io/part-of=flux`), for the services in
[`gitops/platform.yaml`](gitops/platform.yaml) (`global.okdp.proxy`), committed and pushed,
and for the CI's jobs in `proxy` of sandbox-charts'
[`bootstrap/forgejo-runner/values.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/forgejo-runner/values.yaml) (its
`helm upgrade --install` again, step 3).

### Another domain (optional)

The ingress suffix and the OIDC URLs (the five endpoints and the DCR registration URL)
are in [`gitops/platform.yaml`](gitops/platform.yaml), with the S3 endpoints (its
connection `platform-s3`).
Change `okdp.sandbox` there, in `gitops/argocd/ingress.yaml` and
`gitops/argocd/bootstrap/argocd-cm-patch.yaml`, commit and push: every release is
re-rendered. The dependencies take it from their values, in sandbox-charts: `domain` of
`bootstrap/keycloak/values.yaml` and `bootstrap/rustfs/values.yaml`, the hosts of
`bootstrap/forgejo/values.yaml`, the zone of `bootstrap/dns-server/values.yaml`, and
`SUFFIX` of `bootstrap/coredns/patch.sh`; run their commands again (step 3).

### OAuth clients of the services (optional)

The sandbox registers the services' OAuth clients by dynamic client registration
(`global.okdp.oidc.clientProvisioning: dcr`): each service's oidc-dcr Job registers its
client in the realm `okdp` with an initial access token of its namespace
(`global.okdp.oidc.dcr.authMethod: initialAccessToken`; Secret `okdp-dcr-token`, from
OpenBao, where sandbox-charts' `bootstrap/openbao/init.sh` mints one per namespace of
`DCR_NAMESPACES`, `demo` by default, step 3) and writes it to Secret
`<release>-<namespace>-dcr`. The realm refuses anonymous registration (Keycloak's own
client registration policies, [`realm.yaml`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/keycloak/realm.yaml) declares none). The Job runs `quay.io/adaltas/oidc-dcr-job`.
The console's own client (`okdp-ui`) stays declared in the Keycloak realm. The alternative is
`clientProvisioning: existing` (drop the `dcr` block): the services then use the clients declared in
the realm and their Secrets `creds-<release>-oauth2` (`projects/demo/instances/secrets`), whose
`client_secret` is the realm's, read from OpenBao (`demo/keycloak/<client>`, step 3).
JupyterHub's Secret is generated whole, with the crypt key of its users' auth state (an entry of
`local-secrets-provider` generates or reads, not both): its `client_secret` is not the realm's.
Give it to the realm once, then the Keycloak release imports it and keeps it:

```sh
kubectl -n demo get secret creds-demo-jupyterhub-oauth2 -o jsonpath='{.data.client_secret}' \
  | jq -Rn '{data: {jupyterhub: input}}' \
  | kubectl -n keycloak patch secret keycloak-client-secrets --type merge --patch-file /dev/stdin
scripts/bootstrap.sh   # or the helm upgrade of Keycloak and sandbox-charts' bootstrap/openbao/init.sh (step 3)
```

A project of another namespace whose services register clients needs its token: add
the namespace to `DCR_NAMESPACES` and run `scripts/bootstrap.sh` again (or
sandbox-charts' `bootstrap/openbao/init.sh` with it).

### 6. DNS setup

Enable access to OKDP services through DNS resolution for `okdp.sandbox` (or your domain):

- **Option 1 (recommended)**: local DNS server configuration (automatic for all services)
- **Option 2**: manual `/etc/hosts` configuration

See [dns-configuration.md](docs/dns-configuration.md) for your operating system.

### 7. SSL certificate

The sandbox uses a local certificate authority, the cluster issuer of the bootstrap's
cert-manager (step 3). Import it into your system or browser trust store to avoid warnings:

```sh
kubectl get secret default-issuer -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > okdp-sandbox-ca.crt
```

See [install-certificate.md](docs/install-certificate.md). Otherwise, open
https://keycloak.okdp.sandbox first and accept its certificate: every OKDP service talks
to Keycloak.

## Using the sandbox

1. **Console**: https://okdp-ui.okdp.sandbox, login `adm` / `adm` (Keycloak). Keycloak's
   admin console: https://keycloak.okdp.sandbox (`admin`, its password in step 3); the S3 store's:
   https://s3-console.okdp.sandbox (`okdp-root`, its password in step 3).
2. **The demo project** is deployed with the platform: `projects/demo` in Git, namespace
   `demo`. Its services appear in the console like the ones you deploy from it.
3. **Deploy a service** from the console, or commit the same files: see
   [gitops/README.md](gitops/README.md) (`instance.yaml`, `config.yaml`), and push the
   commit to the repository of the sources on Forgejo (`okdp/okdp-projects` in `io`,
   `okdp/okdp-project-<p>` in `split`): the CI compiles it at its next run, within 2
   minutes (the **Actions** tab of `okdp/okdp-output`) and the engine
   deploys the output. From this repository, `scripts/configure.sh --push` puts HEAD
   there, and refuses to overwrite what the console committed since. Everything shows
   up in Forgejo (https://forgejo.okdp.sandbox, **Sign in with keycloak**: `adm` and
   `alice` are site admins): the commits of the sources (the console's, yours), then
   the CI's compile of the output (`okdp: compile`). The
   [okdp CLI](https://github.com/OKDP/okdp-control-plane-cli) does the same from a
   terminal: `okdp login https://okdp-ui.okdp.sandbox` (device flow or browser, the
   console client allows both; add `--insecure-skip-tls-verify` if the sandbox
   certificate is not installed), then `okdp service deploy`.
4. **Examples**: move `gitops/optional/projects/demo/instances/okdp-examples` to
   `gitops/projects/demo/instances/`, commit and push (`scripts/configure.sh --push`):
   the seed Job loads the NYC-taxi lakehouse. Then follow the
   [okdp-examples guide](https://github.com/OKDP/okdp-examples).

## Optional components

Move a project directory of [`gitops/optional/projects`](gitops/optional/projects) to
`gitops/projects/`, commit and push (`scripts/configure.sh --push`). Remove it the same
way (deletion-protected objects, labelled `okdp.io/protected`, must be unlabelled
first).

- **strimzi-operator**, **k8ssandra-operator**, **nifikop**: the operators of the
  community services strimzi, k8ssandra and nifi, once per platform.

The services of the community catalog are in the console's menu (AI, Database,
Workflows, Data Engineering, Streaming): deploy their operator first.

### Another S3 store

The platform's S3 store is a connection: any S3-compatible store OKDP does not manage
(a cloud's, a company's) takes the place of the sandbox's RustFS. Point
the connection `platform-s3` of [`platform.yaml`](gitops/platform.yaml) at it (`apiUrl`,
`internalUrl`, `region`, `bucket`, `pathStyle`), put its access key in the platform's
secret store under the connection's `remoteKey` (the key `platform/s3` of OpenBao's
mount `okdp`, fields `accessKey` and `secretKey`, written with the root token:
`bao kv put -mount=okdp platform/s3 accessKey=... secretKey=...` in the pod
`openbao-0`, as [`bootstrap/openbao/init.sh`](https://github.com/OKDP/sandbox-charts/blob/main/bootstrap/openbao/init.sh) does; run
again, init.sh writes RustFS' key back), create its buckets, commit and push.
A project may declare a store of its own the same way (`connections` of its
`project.yaml`), and the packages keycloak, seaweedfs and rustfs of sandbox-charts may
be deployed as OKDP instances, a project's own store for instance.

## Cleanup

```sh
kind delete cluster --name okdp-sandbox
rm /tmp/okdp-sandbox-config.yaml
docker rm -f okdp-registry   # the registry of the okdp-gitops image (step 2)
```

If you trusted the sandbox CA, remove it too: see
[install-certificate.md](docs/install-certificate.md#removing-the-certificate).

## License

This project is licensed under the [Apache License 2.0](http://www.apache.org/licenses/LICENSE-2.0).

---

**Built 🚀 for the OKDP Community**
<a href="https://okdp.io">
  <img src="https://okdp.io/logos/okdp-notext.svg" height="20px" style="margin: 0 2px;" />
</a>
