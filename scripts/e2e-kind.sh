#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# End-to-end test of one GitOps engine on a throwaway kind cluster, the way the
# README installs the sandbox: kind cluster argocd or fluxcd (own kubeconfig, the
# current context is never used), the platform's dependencies installed with helm
# (scripts/bootstrap.sh, with the bootstrap/ of sandbox-charts at its ref: cert-manager, the CA bundle,
# the tools and the deletion protection, ingress-nginx, the CoreDNS patch, the DNS
# server, CloudNativePG, External Secrets, Keycloak, RustFS, OpenBao and its init,
# Forgejo and its CI runner), the repositories
# of the topology and the service catalogs put on Forgejo by scripts/configure.sh
# --push (organization okdp,
# http://forgejo-http.forgejo.svc.cluster.local:3000/okdp/<repository>.git, branch
# main), the engine, its entry point (the output repository), then a wait until every
# release is ready. Then the CI: a plain commit pushed to the repository of the
# project okdp-system (a Secret added to its instance local-secrets-provider) must be
# compiled into the output by the next scheduled run of the output repository's
# workflow (the runner forgejo/forgejo-runner, the bootstrap's) and deployed; the
# repositories of the sources hold no workflow, the output's main refuses a push of
# anyone but okdp-ci, the CI's account (the admin's, the console's, the engines'
# reader's), and the reader reads the output only.
#
# What is pushed is a copy of the layout at E2E_REF, adapted for the test:
#   - scripts/configure.sh sets the control plane server's gitops.engine to the engine
#     under test and the topology to E2E_TOPOLOGY;
#   - E2E_SERVER_IMAGE and E2E_UI_IMAGE (repository[:tag][@sha256:...]) replace the images of the
#     control plane (load them with E2E_LOAD_IMAGES), E2E_GITOPS_IMAGE the
#     okdp-gitops image of the CI's jobs (sandbox-charts' bootstrap/forgejo-runner), which the runner's
#     own Docker daemon pulls from its registry (an image loaded into the node is not
#     seen: push it to a registry), its registry added to the runner's
#     insecureRegistries (plain HTTP allowed) and to its egress
#     (networkPolicy.registries: the runner's NetworkPolicy lets out the
#     bootstrap's okdp-registry:5000 of the kind network and the internet's 443
#     only): E2E_GITOPS_REGISTRY_CIDR, else the address of the registry's host, a
#     container of the kind network (docker inspect) or a name the host resolves,
#     its port, else 443;
#   - E2E_SKIP_PROJECTS drops these projects (e.g. demo: the platform's only);
#   - then the copy is committed; scripts/configure.sh --push compiles it.
# The service packages are read from the catalogs of catalogs.yaml (Git, at
# their ref): OKDP_CATALOGS, else the checkouts next to this repository, else GitHub
# (scripts/compile.sh); scripts/configure.sh --push copies them to the cluster's
# Forgejo, where the control plane server reads them. The upstream charts come from
# their public repositories.
#
# Usage:
#   e2e-kind.sh up   <argocd|flux>   create, deploy and wait
#   e2e-kind.sh push <argocd|flux>   push E2E_REF again (adapted) to the cluster's Forgejo
#   e2e-kind.sh down <argocd|flux>   delete the cluster
# Environment:
#   E2E_DIR       work directory (kubeconfigs, pushed copy), default ./.e2e
#   E2E_REF       Git ref of this repository to deploy, default HEAD (commit first)
#   E2E_TOPOLOGY  io (default) or split (scripts/configure.sh --topology)
#   OKDP_CATALOGS "NAME=DIR|URL ..." where the catalogs are read from
#   E2E_SERVER_IMAGE, E2E_UI_IMAGE   images of the control plane (repository[:tag][@sha256:...])
#   E2E_GITOPS_IMAGE         the okdp-gitops image of the CI's jobs, in a registry, by digest
#                            (repository[:tag]@sha256:...: it receives the output repository's
#                            write token; without a digest, the one the local Docker holds
#                            for that reference, else the script stops)
#   E2E_GITOPS_REGISTRY_CIDR the runner's egress to that registry (a CIDR, its port
#                            the image's registry's), default its host's address
#   OKDP_GITOPS   the okdp-gitops binary (default: okdp-gitops in PATH)
#   E2E_LOAD_IMAGES          images loaded into the kind node (space separated)
#   E2E_SKIP_PROJECTS        projects left out (space separated), e.g. demo
#   ARGOCD_VERSION  default v3.4.2        FLUX_VERSION  default v2.9.5
#   ARGOCD_INSTALL_SHA256  the sha256 of ARGOCD_VERSION's manifests/install.yaml,
#                 pinned with it (the manifest is applied only if it matches); the
#                 Flux CLI must be of FLUX_VERSION (its embedded manifests installed)
#   E2E_TIMEOUT   seconds, default 2400
# Afterwards: KUBECONFIG=$E2E_DIR/<engine>.kubeconfig kubectl ...

set -euo pipefail

ACTION="${1:-}"; ENGINE="${2:-}"
[[ "$ACTION" =~ ^(up|push|down)$ && "$ENGINE" =~ ^(argocd|flux)$ ]] || { sed -n '18,80p' "$0"; exit 2; }

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
PREFIX="$(git -C "$ROOT" rev-parse --show-prefix)"; PREFIX="${PREFIX%/}"
E2E_DIR="$(mkdir -p "${E2E_DIR:-./.e2e}" && cd "${E2E_DIR:-./.e2e}" && pwd)"
E2E_REF="${E2E_REF:-HEAD}"
E2E_TOPOLOGY="${E2E_TOPOLOGY:-io}"
E2E_LOAD_IMAGES="${E2E_LOAD_IMAGES:-}"
E2E_SKIP_PROJECTS="${E2E_SKIP_PROJECTS:-}"
E2E_SERVER_IMAGE="${E2E_SERVER_IMAGE:-}"
E2E_UI_IMAGE="${E2E_UI_IMAGE:-}"
E2E_GITOPS_IMAGE="${E2E_GITOPS_IMAGE:-}"
E2E_GITOPS_REGISTRY_CIDR="${E2E_GITOPS_REGISTRY_CIDR:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
# sha256 of https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml
# (curl -fsSL "$url" | sha256sum, checked against the release). Update both together,
# here and in .github/workflows/deploy-validation.yml.
ARGOCD_INSTALL_SHA256="${ARGOCD_INSTALL_SHA256:-69114b8c9eb48a1d08598e6f654a0869b10ae902456ea4b70796cb563760f5ec}"
FLUX_VERSION="${FLUX_VERSION:-v2.9.5}"
E2E_TIMEOUT="${E2E_TIMEOUT:-2400}"
CLUSTER="${ENGINE/#flux/fluxcd}"   # argocd, fluxcd
export KUBECONFIG="$E2E_DIR/$ENGINE.kubeconfig"
COPY="$E2E_DIR/$ENGINE-repo"
G="$COPY/$PREFIX"
# The bootstrap of the test (bootstrap/ of sandbox-charts, adapted), and Forgejo as it
# installs it (scripts/lib/forgejo.sh).
BOOTSTRAP_COPY="$E2E_DIR/$ENGINE-bootstrap"
export FORGEJO_VALUES="$BOOTSTRAP_COPY/forgejo/values.yaml"

log() { echo "[$CLUSTER] $*"; }

if [[ "$ACTION" == down ]]; then
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
  rm -rf "$KUBECONFIG" "$COPY" "$BOOTSTRAP_COPY"
  exit 0
fi

# ---------------------------------------------------------- adapted copy
# runner_registry HOST[:PORT]: the runner's egress to the registry of the CI's image
# (networkPolicy.registries of $BOOTSTRAP_COPY/forgejo-runner/values.yaml, which lets
# out okdp-registry:5000 of the kind network and the internet's 443, not the
# private ranges): E2E_GITOPS_REGISTRY_CIDR, else HOST's address, a container of the
# kind network or a name this host resolves; PORT, else 443.
runner_registry() {
  local host="${1%:*}" port=443 cidr="$E2E_GITOPS_REGISTRY_CIDR" ip
  [[ "$1" == *:* ]] && port="${1##*:}"
  if [[ -z "$cidr" ]]; then
    ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$host" 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    [[ -n "$ip" ]] || { log "WARNING: registry $host: no address, the CI runner's jobs may not pull $E2E_GITOPS_IMAGE (set E2E_GITOPS_REGISTRY_CIDR)"; return 0; }
    cidr="$ip/32"
  fi
  CIDR="$cidr" PORT="$port" yq -i '.networkPolicy.registries = ((.networkPolicy.registries // []) + [{"cidr": strenv(CIDR), "port": (strenv(PORT) | tonumber)}] | unique)' \
    "$BOOTSTRAP_COPY/forgejo-runner/values.yaml"
}

# split_image REFERENCE: IMAGE_REPO, IMAGE_TAG and IMAGE_DIGEST of
# repository[:tag][@sha256:...]: the digest after the first @, then the tag at the last
# : of what precedes it, if that : follows the last / (else it is a registry's port).
split_image() {
  local ref="$1" name
  IMAGE_DIGEST="" IMAGE_TAG=""
  if [[ "$ref" == *@* ]]; then IMAGE_DIGEST="${ref#*@}"; ref="${ref%%@*}"; fi
  name="${ref##*/}"
  if [[ "$name" == *:* ]]; then IMAGE_TAG="${name##*:}"; ref="${ref%:*}"; fi
  IMAGE_REPO="$ref"
  [[ -z "$IMAGE_DIGEST" || "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { log "image $1: the digest must be sha256:<64 hex>"; exit 1; }
}

# prepare_copy: $COPY =the repository at E2E_REF with the test adaptations,
# committed on top of E2E_REF (a fresh history each time: the push is forced), and
# $BOOTSTRAP_COPY = the bootstrap/ of the catalog sandbox-charts as the copy's
# catalogs.yaml reads it (OKDP_CATALOGS, else the checkout next to this repository,
# else GitHub, at its ref), adapted too.
prepare_copy() {
  rm -rf "$COPY"; mkdir -p "$COPY"
  git -C "$(git -C "$ROOT" rev-parse --show-toplevel)" archive "$E2E_REF" | tar -x -C "$COPY"
  rm -rf "$BOOTSTRAP_COPY"
  (
    PROG=e2e
    ROOT="$G"
    # shellcheck source=lib/topology.sh
    source "$SCRIPTS/lib/topology.sh"
    work_init
    catalog_sources_init
    bootstrap_resolve
    cp -R "$BOOTSTRAP" "$BOOTSTRAP_COPY"
  )
  for p in $E2E_SKIP_PROJECTS; do rm -rf "${G:?}/projects/$p"; done
  local c image registry
  for c in server ui; do
    image="E2E_${c^^}_IMAGE"; image="${!image}"
    [[ -n "$image" ]] || continue
    split_image "$image"
    # imageTag is the tag of repository:tag, which takes @sha256:... after it.
    REPO="$IMAGE_REPO" TAG="${IMAGE_TAG:-latest}${IMAGE_DIGEST:+@$IMAGE_DIGEST}" \
      yq -i '.imageRepository = strenv(REPO) | .imageTag = strenv(TAG)' \
      "$G/projects/okdp-system/instances/okdp-control-plane-$c/config.yaml"
  done
  if [[ -n "$E2E_GITOPS_IMAGE" ]]; then
    split_image "$E2E_GITOPS_IMAGE"
    # The CI's image receives the output repository's write token: by digest, the
    # runner's chart refuses to render without one. Not given: the digest the local
    # Docker holds for that reference (docker push sets it), else an error.
    if [[ -z "$IMAGE_DIGEST" ]]; then
      IMAGE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$E2E_GITOPS_IMAGE" 2>/dev/null | sed -n 's/^[^@]*@//p' || true)"
      [[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || { log "E2E_GITOPS_IMAGE has no digest: set it to <repository>[:tag]@sha256:... (docker inspect --format '{{index .RepoDigests 0}}' <image>, after docker push)"; exit 1; }
    fi
    REPO="$IMAGE_REPO" TAG="$IMAGE_TAG" DIGEST="$IMAGE_DIGEST" \
      yq -i '.okdpGitopsImage.repository = strenv(REPO) | .okdpGitopsImage.tag = strenv(TAG) | .okdpGitopsImage.digest = strenv(DIGEST)' \
      "$BOOTSTRAP_COPY/forgejo-runner/values.yaml"
    # The registry, when the image names one (a host: a dot or a port).
    registry="${IMAGE_REPO%%/*}"
    if [[ "$IMAGE_REPO" == */* && "$registry" == *[.:]* ]]; then
      REG="$registry" yq -i '.insecureRegistries = ((.insecureRegistries // []) + [strenv(REG)] | unique)' \
        "$BOOTSTRAP_COPY/forgejo-runner/values.yaml"
      runner_registry "$registry"
    fi
  fi
  "$SCRIPTS/configure.sh" --root "$G" --engine "$ENGINE" --topology "$E2E_TOPOLOGY" </dev/null >/dev/null
  git -C "$COPY" init -q -b main
  git -C "$COPY" add -A
  git -C "$COPY" -c user.name=e2e -c user.email=e2e@okdp.io commit -q -m "e2e: $(git -C "$ROOT" rev-parse --short "$E2E_REF") adapted for $ENGINE, $E2E_TOPOLOGY topology"
}

# push_copy: the repositories of the topology and the catalogs, on the cluster's
# Forgejo (organization, repositories, split: the server's token Secret).
push_copy() {
  log "pushing $E2E_REF (adapted, $E2E_TOPOLOGY topology) and the catalogs to Forgejo"
  "$SCRIPTS/configure.sh" --root "$G" --push --force
}

if [[ "$ACTION" == push ]]; then
  prepare_copy; push_copy; exit 0
fi

# ------------------------------------------------------------------ cluster
if kind get clusters | grep -qx "$CLUSTER"; then
  log "cluster exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
  # TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
  # (the containerd registry config_path, for the plain HTTP repo.alliage.io:8082 below)
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s --config - <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
KIND
fi
# TODO(okdp-compiler): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
# The control plane images come from repo.alliage.io:8082, over plain HTTP.
docker exec "$CLUSTER-control-plane" mkdir -p /etc/containerd/certs.d/repo.alliage.io:8082
docker exec -i "$CLUSTER-control-plane" tee /etc/containerd/certs.d/repo.alliage.io:8082/hosts.toml >/dev/null <<'HOSTS'
server = "http://repo.alliage.io:8082"
[host."http://repo.alliage.io:8082"]
  capabilities = ["pull", "resolve"]
HOSTS
[[ "$(kubectl config current-context)" == "kind-$CLUSTER" ]] || { log "unexpected context"; exit 1; }
for image in $E2E_LOAD_IMAGES; do
  kind load docker-image "$image" --name "$CLUSTER"
done

prepare_copy

# ------------------------------------------------- the platform's dependencies
# README, step 3: helm, before anything compiled; the Forgejo admin's Secret is kept
# when the cluster is reused.
log "installing the platform's dependencies (scripts/bootstrap.sh)"
"$SCRIPTS/bootstrap.sh" --dir "$BOOTSTRAP_COPY"
push_copy

# ------------------------------------------------------------------- engine
wait_for() {  # wait_for DESCRIPTION COMMAND...: retry until COMMAND succeeds
  local what="$1"; shift
  local deadline=$((SECONDS + E2E_TIMEOUT))
  until "$@"; do
    (( SECONDS < deadline )) || { log "timeout waiting for $what"; return 1; }
    sleep 20
  done
  log "$what: ok"
}

expected="$(find "$G/projects" -path '*/instances/*/instance.yaml' | wc -l)"

if [[ "$ENGINE" == argocd ]]; then
  log "installing Argo CD $ARGOCD_VERSION"
  # Its manifest downloaded, then checked against the sha256 pinned with the version
  # (a tag of the repository can move): applied only if it matches.
  manifest="$E2E_DIR/argocd-install-$ARGOCD_VERSION.yaml"
  curl -fsSLo "$manifest" "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  sum="$(sha256sum "$manifest" | cut -d' ' -f1)"
  [[ -n "$ARGOCD_INSTALL_SHA256" ]] \
    || { log "ERROR: no ARGOCD_INSTALL_SHA256 for Argo CD $ARGOCD_VERSION (its install.yaml downloaded is $sum: check it, then pin it with the version)"; exit 1; }
  [[ "$sum" == "$ARGOCD_INSTALL_SHA256" ]] \
    || { log "ERROR: Argo CD $ARGOCD_VERSION install.yaml: sha256 $sum, not the pinned ARGOCD_INSTALL_SHA256 $ARGOCD_INSTALL_SHA256"; exit 1; }
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts -f "$manifest"
  # The health of Applications: the sync waves of the apps of apps (layer ordering);
  # the sign-in with Keycloak and its roles, Keycloak's certificate checked against the
  # platform's CA bundle (Secret certs-bundle of the namespace, trust-manager's): rootCA
  # of oidc.config, added to the patch (README, step 5a).
  certs_bundle() { kubectl -n argocd get secret certs-bundle >/dev/null 2>&1; }
  wait_for "Secret argocd/certs-bundle" certs_bundle
  kubectl -n argocd get secret certs-bundle -o jsonpath='{.data.ca\.crt}' | base64 -d >"$E2E_DIR/argocd-ca.crt"
  CA_FILE="$E2E_DIR/argocd-ca.crt" yq '.data["oidc.config"] |= (from_yaml | .rootCA = load_str(strenv(CA_FILE)) | to_yaml)' \
    "$G/argocd/bootstrap/argocd-cm-patch.yaml" \
    | kubectl -n argocd patch configmap argocd-cm --type merge --patch-file /dev/stdin
  kubectl -n argocd patch configmap argocd-rbac-cm --type merge --patch-file "$G/argocd/bootstrap/argocd-rbac-cm-patch.yaml"
  # argocd-server reads the OIDC settings at startup only.
  kubectl -n argocd rollout restart deployment argocd-server
  kubectl -n argocd rollout status deployment --timeout=10m
  kubectl -n argocd rollout status statefulset --timeout=10m
  kubectl apply -n argocd -f "$G/argocd/"
  argo_ready() {
    local n
    n="$(kubectl get applications.argoproj.io -n argocd -l okdp.io/instance -o json 2>/dev/null \
      | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy"
          and .status.operationState.phase == "Succeeded")] | length')"
    # The operation too: an Application stays Synced/Healthy while a failing hook
    # (e.g. a schema Job) keeps its sync operation retrying.
    log "Applications synced and healthy, last sync succeeded: ${n:-0}/$expected"
    [[ "${n:-0}" == "$expected" ]]
  }
  wait_for "Applications synced and healthy" argo_ready
  kubectl get applications.argoproj.io -n argocd
else
  log "installing Flux $FLUX_VERSION"
  # The manifests embedded in the Flux CLI, nothing downloaded: flux install
  # downloads them from GitHub, unchecked, for a version other than the CLI's own.
  cli="$(flux version --client -o json | jq -r '.flux')"
  [[ "$cli" == "$FLUX_VERSION" ]] \
    || { log "ERROR: the Flux CLI is $cli, FLUX_VERSION $FLUX_VERSION: install the CLI of FLUX_VERSION (or FLUX_VERSION=$cli)"; exit 1; }
  flux install --version="$FLUX_VERSION" --components=source-controller,kustomize-controller,helm-controller
  # Chart version without the OCI digest (see gitops/README.md, "Install with Flux").
  # Cross-namespace source references disabled: a project's HelmRelease
  # cannot reference a source of another namespace. Default service account
  # set to a nonexistent one: a release without an explicit service account
  # gets no permissions.
  kubectl -n flux-system patch deployment helm-controller --type json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"},
         {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--no-cross-namespace-refs=true"},
         {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-service-account=okdp-none"}]'
  kubectl -n flux-system patch deployment kustomize-controller --type json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--no-cross-namespace-refs=true"},
         {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-service-account=okdp-none"}]'
  kubectl -n flux-system rollout status deployment helm-controller --timeout=5m
  kubectl -n flux-system rollout status deployment kustomize-controller --timeout=5m
  kubectl apply -f "$G/flux/sync.yaml"
  flux_ready() {
    local n
    n="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -n okdp-releases -o json 2>/dev/null \
      | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"
    log "HelmReleases ready: ${n:-0}/$expected"
    [[ "${n:-0}" == "$expected" ]]
  }
  wait_for "HelmReleases ready" flux_ready
  flux get kustomizations
  flux get helmreleases -n okdp-releases
fi
# Forgejo's sign-in with Keycloak (README, after step 5): Forgejo reads the sandbox CA
# bundle at startup, and the bundle did not exist when it was bootstrapped; then its OAuth
# source, added or updated in Forgejo's database (not by the chart, which would need
# Keycloak at every start) by scripts/configure.sh --push --sign-in, with the
# group-team map of the platform's admins and of the projects' groups.
log "restarting Forgejo, then its OAuth source keycloak (scripts/configure.sh --push --sign-in)"
kubectl -n forgejo rollout restart deployment forgejo
kubectl -n forgejo rollout status deployment forgejo --timeout=5m
"$SCRIPTS/configure.sh" --root "$G" --push --force --sign-in

# --------------------------------------------------------- a plain commit deploys
# The CI (forgejo/forgejo-runner runs the workflow scripts/configure.sh --push put in
# the output repository, on its schedule): a commit of the sources, pushed to Forgejo
# by neither the console nor configure.sh, is compiled into the output repository by
# the next run, then deployed by the engine. The commit adds a Secret to
# okdp-system/local-secrets-provider; the last commit of the output must be the CI's.
# Before it, the output's branch protection and the accounts: a push to its main of
# the admin, of the console (its token, Secret gitops.credentialsSecret) and of the
# engines' reader (Secret argocd/okdp-gitops-reader) is refused (okdp-ci, the CI's
# account, alone pushes there), the reader cannot read the platform's repository,
# and the sources hold no workflow.
ci_check() (
  PROG=e2e
  ROOT="$G"
  # shellcheck source=lib/topology.sh
  source "$SCRIPTS/lib/topology.sh"
  # shellcheck source=lib/forgejo.sh
  source "$SCRIPTS/lib/forgejo.sh"
  local owner repo dir marker output who user password creds
  work_init
  forgejo_init
  forgejo_connect
  owner="$(forgejo_owner)"
  case "$(topology_current)" in
    io) repo="$PROJECTS_REPO"; dir=projects/okdp-system ;;
    split) repo="${PROJECT_REPO_PREFIX}okdp-system"; dir=. ;;
  esac
  output="$(output_repo "$(topology_current)")"
  forgejo_git clone -q "$(forgejo_repo_url "$owner" "$output")" "$WORK/output"
  forgejo_git -C "$WORK/output" commit -q --allow-empty -m "e2e: a push to the output"
  creds="$(yq '.gitops.credentialsSecret' "$SERVER_VALUES")"
  for who in "admin" "console $SERVER_NAMESPACE/$creds" "reader argocd/okdp-gitops-reader"; do
    if [[ "$who" == admin ]]; then
      user="$FORGEJO_USER"; password="$FORGEJO_PASSWORD"
    else
      read -r _ creds <<<"$who"
      user="$(secret_value "${creds%%/*}" "${creds#*/}" username)"
      password="$(secret_value "${creds%%/*}" "${creds#*/}" password)"
    fi
    if forgejo_git_as "$user" "$password" -C "$WORK/output" push -q "$(forgejo_repo_url "$owner" "$output")" HEAD:main 2>/dev/null; then
      log "the ${who%% *} ($user) pushed to $owner/$output main: its branch protection lets others than $FORGEJO_CI push"
      return 1
    fi
    log "$owner/$output main refuses the push of the ${who%% *} ($user)"
  done
  # The reader reads the output only.
  if forgejo_git_as "$user" "$password" ls-remote "$(forgejo_repo_url "$owner" "$PLATFORM_REPO")" >/dev/null 2>&1; then
    log "the reader ($user) reads $owner/$PLATFORM_REPO: it must read the output only"
    return 1
  fi
  log "the reader ($user) cannot read $owner/$PLATFORM_REPO"
  marker="e2e-$(date +%s)"
  forgejo_git clone -q "$(forgejo_repo_url "$owner" "$repo")" "$WORK/sources"
  if [[ -e "$WORK/sources/.forgejo" ]]; then
    log "$owner/$repo holds .forgejo/: the sources hold no workflow"
    return 1
  fi
  # An entry generates its credentials or reads them from the store: this one
  # generates a key, the marker is a static one.
  M="$marker" yq -i '.secrets += [{"name": "okdp-e2e-ci", "generate": [{"key": "token"}], "data": {"marker": strenv(M)}}]' \
    "$WORK/sources/$dir/instances/local-secrets-provider/config.yaml"
  forgejo_git -C "$WORK/sources" commit -q -am "e2e: a plain commit of the sources"
  forgejo_git -C "$WORK/sources" push -q origin HEAD:main
  log "pushed a commit of the sources to $owner/$repo: Secret okdp-e2e-ci ($marker)"
  ci_deployed() {
    [[ "$(kubectl -n okdp-system get secret okdp-e2e-ci -o jsonpath='{.data.marker}' 2>/dev/null | base64 -d)" == "$marker" ]]
  }
  wait_for "the commit compiled by the CI (its schedule) and deployed" ci_deployed
  forgejo_api GET "/repos/$owner/$output/commits?sha=main&limit=1"
  [[ "$(jq -r '.[0].commit.message' "$FORGEJO_BODY")" == "okdp: compile"* ]] \
    || { log "the last commit of the output is not the CI's: $(jq -r '.[0].commit.message' "$FORGEJO_BODY")"; return 1; }
  log "the output was compiled by the CI"
)
ci_check
log "done; KUBECONFIG=$KUBECONFIG"
