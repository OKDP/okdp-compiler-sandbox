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
# release is ready. Then the CI of the sources: a plain commit pushed to the repository
# of the project okdp-system (a Secret added to its instance local-secrets-provider)
# must be compiled by the CI runner (forgejo/forgejo-runner, the bootstrap's) into the output and
# deployed.
#
# What is pushed is a copy of the layout at E2E_REF, adapted for the test:
#   - scripts/configure.sh sets the control plane server's gitops.engine to the engine
#     under test and the topology to E2E_TOPOLOGY;
#   - E2E_SERVER_IMAGE and E2E_UI_IMAGE (repository:tag) replace the images of the
#     control plane (load them with E2E_LOAD_IMAGES), E2E_GITOPS_IMAGE the
#     okdp-gitops image of the CI's jobs (sandbox-charts' bootstrap/forgejo-runner), which the runner's
#     own Docker daemon pulls from its registry (an image loaded into the node is not
#     seen: push it to a registry), its registry added to the runner's
#     insecureRegistries (plain HTTP allowed);
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
#   E2E_TOPOLOGY  mono (default), io or split (scripts/configure.sh --topology)
#   OKDP_CATALOGS "NAME=DIR|URL ..." where the catalogs are read from
#   E2E_SERVER_IMAGE, E2E_UI_IMAGE   images of the control plane (repository:tag)
#   E2E_GITOPS_IMAGE         the okdp-gitops image of the CI's jobs (repository:tag, in a registry)
#   OKDP_GITOPS   the okdp-gitops binary (default: okdp-gitops in PATH)
#   E2E_LOAD_IMAGES          images loaded into the kind node (space separated)
#   E2E_SKIP_PROJECTS        projects left out (space separated), e.g. demo
#   ARGOCD_VERSION  default v3.4.2        FLUX_VERSION  default v2.9.5
#   E2E_TIMEOUT   seconds, default 2400
# Afterwards: KUBECONFIG=$E2E_DIR/<engine>.kubeconfig kubectl ...

set -euo pipefail

ACTION="${1:-}"; ENGINE="${2:-}"
[[ "$ACTION" =~ ^(up|push|down)$ && "$ENGINE" =~ ^(argocd|flux)$ ]] || { sed -n '18,65p' "$0"; exit 2; }

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
PREFIX="$(git -C "$ROOT" rev-parse --show-prefix)"; PREFIX="${PREFIX%/}"
E2E_DIR="$(mkdir -p "${E2E_DIR:-./.e2e}" && cd "${E2E_DIR:-./.e2e}" && pwd)"
E2E_REF="${E2E_REF:-HEAD}"
E2E_TOPOLOGY="${E2E_TOPOLOGY:-mono}"
E2E_LOAD_IMAGES="${E2E_LOAD_IMAGES:-}"
E2E_SKIP_PROJECTS="${E2E_SKIP_PROJECTS:-}"
E2E_SERVER_IMAGE="${E2E_SERVER_IMAGE:-}"
E2E_UI_IMAGE="${E2E_UI_IMAGE:-}"
E2E_GITOPS_IMAGE="${E2E_GITOPS_IMAGE:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
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
# prepare_copy: $COPY = the repository at E2E_REF with the test adaptations,
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
    REPO="${image%:*}" TAG="${image##*:}" yq -i '.imageRepository = strenv(REPO) | .imageTag = strenv(TAG)' \
      "$G/projects/okdp-system/instances/okdp-control-plane-$c/config.yaml"
  done
  if [[ -n "$E2E_GITOPS_IMAGE" ]]; then
    REPO="${E2E_GITOPS_IMAGE%:*}" TAG="${E2E_GITOPS_IMAGE##*:}" \
      yq -i '.okdpGitopsImage.repository = strenv(REPO) | .okdpGitopsImage.tag = strenv(TAG)' \
      "$BOOTSTRAP_COPY/forgejo-runner/values.yaml"
    # The registry, when the image names one (a host: a dot or a port).
    registry="${E2E_GITOPS_IMAGE%%/*}"
    if [[ "$E2E_GITOPS_IMAGE" == */* && "$registry" == *[.:]* ]]; then
      REG="$registry" yq -i '.insecureRegistries = ((.insecureRegistries // []) + [strenv(REG)] | unique)' \
        "$BOOTSTRAP_COPY/forgejo-runner/values.yaml"
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
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  # The health of Applications: the sync waves of the apps of apps (layer ordering);
  # the sign-in with Keycloak and its roles.
  kubectl -n argocd patch configmap argocd-cm --type merge --patch-file "$G/argocd/bootstrap/argocd-cm-patch.yaml"
  kubectl -n argocd patch configmap argocd-rbac-cm --type merge --patch-file "$G/argocd/bootstrap/argocd-rbac-cm-patch.yaml"
  # argocd-server reads the OIDC TLS setting at startup only.
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
# Forgejo's sign-in with Keycloak (README, after step 4): Forgejo reads the sandbox CA
# bundle at startup, and the bundle did not exist when it was bootstrapped; then its OAuth
# source, added or updated in Forgejo's database (not by the chart, which would need
# Keycloak at every start), with the secret of the realm's client forgejo (Secret
# keycloak/keycloak-client-secrets, generated at the bootstrap), given to the pod on
# its standard input.
log "restarting Forgejo, then its OAuth source keycloak"
kubectl -n forgejo rollout restart deployment forgejo
kubectl -n forgejo rollout status deployment forgejo --timeout=5m
forgejo_auth() { kubectl -n forgejo exec deploy/forgejo -c forgejo -- forgejo admin auth "$@"; }
# forgejo_oauth ARGS...: forgejo admin auth ARGS --secret <the client's secret>.
forgejo_oauth() {
  local secret
  secret="$(kubectl -n keycloak get secret keycloak-client-secrets -o jsonpath='{.data.forgejo}' | base64 -d)"
  [[ -n "$secret" ]] || { log "no secret of the client forgejo in Secret keycloak/keycloak-client-secrets"; return 1; }
  printf '%s\n' "$secret" | kubectl -n forgejo exec -i deploy/forgejo -c forgejo -- \
    sh -c 'read -r secret && exec forgejo admin auth "$@" --secret "$secret"' sh "$@"
}
oauth=(--name keycloak --provider openidConnect --key forgejo
  --auto-discover-url https://keycloak.okdp.sandbox/realms/master/.well-known/openid-configuration
  --group-claim-name groups --admin-group platform_admin)
id="$(forgejo_auth list | awk '$2 == "keycloak" {print $1}')"
if [[ -n "$id" ]]; then
  forgejo_oauth update-oauth --id "$id" "${oauth[@]}"
else
  forgejo_oauth add-oauth "${oauth[@]}"
fi

# --------------------------------------------------------- a plain commit deploys
# The CI of the sources (forgejo/forgejo-runner runs the workflow scripts/configure.sh
# --push put in the repositories of the sources): a commit of the sources, pushed to
# Forgejo by neither the console nor configure.sh, is compiled into the output
# repository by the CI, then deployed by the engine. The commit adds a Secret to
# okdp-system/local-secrets-provider; the last commit of the output must be the CI's.
ci_check() (
  PROG=e2e
  ROOT="$G"
  # shellcheck source=lib/topology.sh
  source "$SCRIPTS/lib/topology.sh"
  # shellcheck source=lib/forgejo.sh
  source "$SCRIPTS/lib/forgejo.sh"
  local owner repo dir marker
  work_init
  forgejo_init
  forgejo_connect
  owner="$(forgejo_owner)"
  case "$(topology_current)" in
    mono) repo="$(mono_repo)"; dir=projects/okdp-system ;;
    io) repo="$INPUT_REPO"; dir=projects/okdp-system ;;
    split) repo="${PROJECT_REPO_PREFIX}okdp-system"; dir=. ;;
  esac
  marker="e2e-$(date +%s)"
  forgejo_git clone -q "$(forgejo_repo_url "$owner" "$repo")" "$WORK/sources"
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
  wait_for "the commit compiled by the CI and deployed" ci_deployed
  forgejo_api GET "/repos/$owner/$(output_repo "$(topology_current)")/commits?sha=main&limit=1"
  [[ "$(jq -r '.[0].commit.message' "$FORGEJO_BODY")" == "okdp: compile"* ]] \
    || { log "the last commit of the output is not the CI's: $(jq -r '.[0].commit.message' "$FORGEJO_BODY")"; return 1; }
  log "the output was compiled by the CI"
)
ci_check
log "done; KUBECONFIG=$KUBECONFIG"
