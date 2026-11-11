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

# Installs the dependencies of the platform with helm, the README's step 3, into the
# cluster of the current kubectl context (KUBECONFIG): what the compiled tree needs
# and OKDP does not compile, each a release of its upstream chart, or of a chart of
# bootstrap/ (bootstrap/charts.yaml), with its values of bootstrap/. bootstrap/ is the
# catalog sandbox-charts', read as the catalogs are (scripts/compile.sh): at its ref of
# gitops/catalogs.yaml, from --catalog sandbox-charts=SRC or OKDP_CATALOGS, else the
# checkout next to this repository, else GitHub; its README lists the commands:
#   0. the namespaces of the releases, each with its Pod Security level
#      (bootstrap/namespaces.yaml: baseline enforced, restricted warned and
#      audited; forgejo privileged, the CI runner's Docker daemon), applied first so
#      that no release creates its namespace unlabelled (--create-namespace finds
#      them);
#   1. cert-manager (its own approver off), approver-policy and its policies
#      (bootstrap/approver-policy/policies.yaml: default-issuer signs a project's own
#      hosts only), trust-manager and the cluster issuer default-issuer, a CA minted
#      in the cluster (namespace cert-manager), then the CA bundle of every namespace
#      (bootstrap/trust-manager/bundle.yaml, Secret and ConfigMap certs-bundle);
#   2. Reloader (kube-tools), the deletion protection and the bounds of the pods and
#      hosts (bootstrap/protection/policies.yaml, ingress-hosts.yaml); no replicator;
#   3. ingress-nginx (ingress-nginx), then the cluster's CoreDNS patched to answer the
#      ingress suffix with its Service (bootstrap/coredns/patch.sh), and the DNS
#      server of the host (dns-server, a CoreDNS on the node port 30053);
#   4. CloudNativePG, the PostgreSQL operator (cnpg-system);
#   5. External Secrets (external-secrets);
#   6. Keycloak (keycloak): its admin account in Secret keycloak/keycloak-admin, a
#      random password created once, its database, a CloudNativePG cluster, the
#      secrets of the realm's clients, generated once
#      (bootstrap/keycloak/client-secrets.sh: Secret keycloak/keycloak-client-secrets,
#      none in Git), then Keycloak and its realms, okdp (the applications and the
#      people, which reads them) and master (Keycloak's administrators only);
#   7. RustFS, the S3 store (rustfs): its buckets, and the platform's access key;
#   8. OpenBao (openbao), the platform's secret store, then its init
#      (bootstrap/openbao/init.sh): initialized and unsealed (SANDBOX ONLY: its
#      unseal key in Secret openbao/openbao-init; its root token revoked once the
#      role okdp-bootstrap signs in, every run signed in as the ServiceAccount
#      openbao/okdp-bootstrap), the KV mount, the
#      Kubernetes auth and the policy of the namespaces (no namespace reads
#      platform/), the platform's S3 identity under <namespace>/s3/platform of the
#      namespaces of bootstrap/openbao/s3.yaml (demo); the secret of each client of
#      the realm under <namespace>/keycloak/<client> (property client_secret) of
#      the namespaces that read it (bootstrap/openbao/clients.yaml), where the
#      compiled instances read it; an initial access token of the realm okdp per
#      namespace of DCR_NAMESPACES (demo by default), with which its services
#      register their OAuth clients (the realm refuses anonymous registration);
#   9. Forgejo (forgejo), the Git server of the deployments repositories and of the
#      catalogs, its admin account in Secret forgejo/okdp-forgejo-admin, a random
#      password created once, then its CI runner (bootstrap/forgejo-runner, a chart of
#      this repository), whose pod starts once scripts/configure.sh --push registers it.
# Every chart is installed by its content, which bootstrap/charts.yaml pins: the
# package of a chart of a repository checked against its sha256 first, an OCI chart
# by the digest of its manifest; one without a pin is refused. The images are pinned
# by digest in the values files.
# Every step is idempotent (helm upgrade --install, the admin, client and init
# Secrets kept when they exist): run it again to upgrade. Then scripts/configure.sh --push
# (README, step 4).
#
# Its scripts (coredns/patch.sh, keycloak/client-secrets.sh, openbao/init.sh) run with
# the operator's rights, cluster-admin: read from a Git URL (GitHub, --catalog
# sandbox-charts=URL), bootstrap/ is that of the commit catalogs.yaml pins as
# sandbox-charts' ref, fetched by its hash, never a branch's head; a branch or a tag
# as that ref is refused unless --allow-branch. A directory (--dir, --catalog
# sandbox-charts=DIR) or the checkout next to this repository (read at the ref) is
# the operator's own input, read as it is.
#
# The CI runner's okdp-gitops image is named by its digest (it receives the output
# repository's write token): --gitops-digest, OKDP_GITOPS_IMAGE_DIGEST, or the
# okdpGitopsImage.digest of bootstrap/forgejo-runner/values.yaml (--dir); without one
# nothing is installed (README, step 2: the digest of the image pushed to the registry).
#
# Usage: bootstrap.sh [--dir DIR] [--catalog NAME=SRC]... [--allow-branch]
#                     [--gitops-digest sha256:...]
#   --dir DIR             the bootstrap directory, its values and manifests (default:
#                         bootstrap/ of the catalog sandbox-charts, as above)
#   --catalog NAME=SRC    where a catalog is read from (a directory, read as it is, or
#                         a Git URL, read at its ref)
#   --gitops-digest D     the digest of the okdp-gitops image of the CI's jobs
#   --allow-branch        read bootstrap/ from a Git URL at a branch or a tag of
#                         catalogs.yaml (its head when it runs: what it runs is
#                         whatever the branch holds then)
# Requires kubectl, helm (installing oci://...@sha256:... references: 4.3 tested), yq v4, jq and awk (the CoreDNS
# patch, OpenBao's init), git (the catalog).

set -euo pipefail

PROG=bootstrap
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
DIR=""
CATALOGS=()
ALLOW_BRANCH=false
GITOPS_DIGEST="${OKDP_GITOPS_IMAGE_DIGEST:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$(cd "$2" && pwd)"; shift 2 ;;
    --catalog) CATALOGS+=("$2"); shift 2 ;;
    --allow-branch) ALLOW_BRANCH=true; shift ;;
    --gitops-digest) GITOPS_DIGEST="$2"; shift 2 ;;
    -h|--help) sed -n '18,96p' "$0"; exit 0 ;;
    *) echo "bootstrap: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for c in kubectl helm yq jq awk; do
  command -v "$c" >/dev/null || { echo "bootstrap: $c is required" >&2; exit 2; }
done
if [[ -z "$DIR" ]]; then
  # shellcheck source=lib/topology.sh
  source "$SCRIPTS/lib/topology.sh"
  work_init ""
  catalog_sources_init "${CATALOGS[@]}"
  # From a Git URL, the commit pinned: a branch's head would run whatever it holds.
  read -r kind src <<<"$(catalog_origin "$BOOTSTRAP_CATALOG")"
  ref="$(catalog_ref "$BOOTSTRAP_CATALOG")"
  if [[ "$kind" == url ]] && ! catalog_ref_is_commit "$ref" && ! $ALLOW_BRANCH; then
    die "catalog $BOOTSTRAP_CATALOG: ref '$ref' of catalogs.yaml is not a commit hash, and bootstrap/ of $src runs with your cluster-admin: pin the commit (scripts/bump-catalogs.sh), or --allow-branch, or --catalog $BOOTSTRAP_CATALOG=DIR, or --dir DIR"
  fi
  bootstrap_resolve
  DIR="$BOOTSTRAP"
fi
echo "bootstrap: $DIR"
# The runner's image, before anything is installed: its chart refuses to render without a digest.
[[ -n "$GITOPS_DIGEST" ]] || GITOPS_DIGEST="$(yq '.okdpGitopsImage.digest // ""' "$DIR/forgejo-runner/values.yaml")"
[[ "$GITOPS_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || { echo "bootstrap: no digest of the okdp-gitops image of the CI's jobs (sha256:<64 hex>): --gitops-digest, OKDP_GITOPS_IMAGE_DIGEST or okdpGitopsImage.digest of $DIR/forgejo-runner/values.yaml (README, step 2)" >&2; exit 2; }

step() { echo; echo "== $*"; }
declare -F die >/dev/null || die() { echo "bootstrap: $*" >&2; exit 1; }

# release NAME [--no-wait]: helm upgrade --install of the release NAME of charts.yaml,
# waiting for it (and for its hooks) but with --no-wait. A chart that is not of the
# bootstrap's directory is installed by its content, which charts.yaml pins: an OCI
# chart by the digest of its manifest (oci://...@sha256:..., no version), a chart of a
# repository from the package helm pull downloads, whose sha256 must be the pinned
# one; a chart with neither is refused.
release() {
  local r=".releases[\"$1\"]" chart repo path sha digest version pull="" rc=0 args=() v
  chart="$(yq "$r.chart" "$DIR/charts.yaml")"
  repo="$(yq "$r.repo // \"\"" "$DIR/charts.yaml")"
  path="$(yq "$r.path // \"\"" "$DIR/charts.yaml")"
  sha="$(yq "$r.sha256 // \"\"" "$DIR/charts.yaml")"
  digest="$(yq "$r.digest // \"\"" "$DIR/charts.yaml")"
  version="$(yq "$r.version // \"\"" "$DIR/charts.yaml")"
  if [[ -n "$path" ]]; then
    chart="$DIR/$path"
  elif [[ -n "$digest" ]]; then
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "charts.yaml: release $1: digest $digest is not sha256:<64 hex>"
    chart="$chart@$digest"
  elif [[ -n "$repo" ]]; then
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "charts.yaml: release $1 (chart $chart of $repo): no sha256 of its package, nothing is installed unpinned (scripts/bump-bootstrap.sh prints it)"
    pull="$(mktemp -d)"
    helm pull "$chart" --repo "$repo" --version "$version" -d "$pull" >/dev/null 2>"$pull/log" \
      || { cat "$pull/log" >&2; rm -rf "$pull"; die "helm pull of $chart $version from $repo failed"; }
    local pkg got
    pkg="$(find "$pull" -maxdepth 1 -name '*.tgz')"
    got="$(sha256sum "$pkg" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
      rm -rf "$pull"
      die "chart $chart $version of $repo: the package's sha256 is $got, not the $sha pinned for release $1 in charts.yaml: refused (scripts/bump-bootstrap.sh)"
    fi
    chart="$pkg"
  else
    die "charts.yaml: release $1 (chart $chart): no sha256 (repo) nor digest (oci://) pin"
  fi
  args+=(-n "$(yq "$r.namespace" "$DIR/charts.yaml")" --create-namespace)
  if [[ "${2:-}" != --no-wait ]]; then
    args+=(--wait --timeout "$(yq "$r.timeout // \"5m\"" "$DIR/charts.yaml")")
  fi
  while IFS= read -r v; do args+=(-f "$DIR/$v"); done < <(yq "$r.values[]" "$DIR/charts.yaml")
  if [[ "$1" == forgejo-runner ]]; then args+=(--set "okdpGitopsImage.digest=$GITOPS_DIGEST"); fi
  helm upgrade --install "$1" "$chart" "${args[@]}" || rc=$?
  [[ -z "$pull" ]] || rm -rf "$pull"
  return "$rc"
}

echo "Installing the platform's dependencies into the context $(kubectl config current-context)"

# The namespaces first, with their Pod Security labels: a release's
# --create-namespace would create its namespace without them.
step "The namespaces and their Pod Security levels"
[[ -f "$DIR/namespaces.yaml" ]] \
  || { echo "bootstrap: $DIR has no namespaces.yaml (the namespaces' Pod Security levels): a bootstrap of sandbox-charts older than this script" >&2; exit 1; }
kubectl apply -f "$DIR/namespaces.yaml"
# The default deny of the ingress of the namespaces no release brings one for, and the
# ports of their webhooks.
[[ -f "$DIR/network-policies.yaml" ]] \
  || { echo "bootstrap: $DIR has no network-policies.yaml (the default deny of the namespaces without a NetworkPolicy): a bootstrap of sandbox-charts older than this script" >&2; exit 1; }
kubectl apply -f "$DIR/network-policies.yaml"

step "cert-manager, approver-policy and its policies, trust-manager, the cluster issuer and the CA bundle"
release cert-manager
# The requests wait for a policy: the policies before trust-manager and the issuers.
release approver-policy
kubectl apply -f "$DIR/approver-policy/policies.yaml"
release trust-manager
release cert-issuers
kubectl apply -f "$DIR/trust-manager/bundle.yaml"

step "Reloader and the deletion protection"
release reloader
kubectl apply -f "$DIR/protection/policies.yaml"
[[ -f "$DIR/protection/ingress-hosts.yaml" ]] || { echo "bootstrap: $DIR has no protection/ingress-hosts.yaml: a bootstrap of sandbox-charts older than this script" >&2; exit 1; }
kubectl apply -f "$DIR/protection/ingress-hosts.yaml"

step "ingress-nginx, the CoreDNS patch and the DNS server of the host"
release ingress-nginx
"$DIR/coredns/patch.sh"
release dns-server

step "CloudNativePG"
release cloudnative-pg

step "External Secrets"
release external-secrets

step "Keycloak and its database"
if ! kubectl -n keycloak get secret keycloak-admin >/dev/null 2>&1; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | kubectl -n keycloak create secret generic \
    keycloak-admin --from-file=admin-password=/dev/stdin
fi
kubectl apply -f "$DIR/keycloak/database.yaml"
# The operator writes the cluster's status a moment after the object.
for _ in $(seq 30); do
  [[ -n "$(kubectl -n keycloak get clusters.postgresql.cnpg.io keycloak-db -o jsonpath='{.status.phase}' 2>/dev/null)" ]] && break
  sleep 2
done
kubectl -n keycloak wait clusters.postgresql.cnpg.io/keycloak-db --for=condition=Ready --timeout=10m
"$DIR/keycloak/client-secrets.sh"
release keycloak

step "RustFS, the S3 store, and the platform's access key"
release rustfs

step "OpenBao, the platform's secret store"
release openbao
# DCR_NAMESPACES: the non-privileged project namespaces whose services register their
# OAuth clients by DCR (platform.yaml, authMethod: initialAccessToken); init.sh mints
# an initial access token per namespace and writes it to the store.
DCR_NAMESPACES="${DCR_NAMESPACES:-demo}" "$DIR/openbao/init.sh"

step "Forgejo"
if ! kubectl -n forgejo get secret okdp-forgejo-admin >/dev/null 2>&1; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | kubectl -n forgejo create secret generic \
    okdp-forgejo-admin --from-literal=username=okdp-admin --from-file=password=/dev/stdin
fi
release forgejo

step "The CI runner"
# Its pod waits for its registration Secret (scripts/configure.sh --push).
release forgejo-runner --no-wait

cat <<EOF

The platform's dependencies are installed. Next: configure and push the layout to
Forgejo, scripts/configure.sh --push (README, step 4).
EOF
