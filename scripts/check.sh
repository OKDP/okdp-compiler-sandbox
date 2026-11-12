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

# CI check of the deployments layout (see gitops/README.md). The rules of the tree
# (names, releases, platform.yaml, project.yaml, instance.yaml, config.yaml,
# connections.yaml, the connections and their contracts, the claims, catalogs.yaml)
# are okdp-compiler's and okdp-gitops': the compile (4.) reports them, this script
# re-implements none. It checks the sandbox itself:
#   1. the files the scripts and the engines read beside the compile parse (the
#      server's values, catalogs.yaml, projects.yaml, platform.yaml, argocd/, flux/);
#      a catalog of catalogs.yaml at a branch or a tag, not a commit, warned of;
#   2. the sandbox's files agree with its scripts: the control plane server names the
#      sandbox's io or split topology (gitops.topology; no single repository, mono is
#      gone; io warned of: every writer of the projects repository writes every
#      project); flux/ and argocd/ read the output repository of the topology (the
#      AppProjects too; the app of apps of the instances writes Applications in
#      argocd only, its AppProject okdp.instances; Argo CD's admins are the
#      administrators' groups of platform.yaml, no default role); the OIDC
#      provider's certificate is checked (platform.yaml oidc.insecureSkipVerify,
#      Argo CD's oidc.tls.insecure.skip.verify, the console's keycloak.tlsInsecure
#      false); the secret store's provider is https, its CA given, its tokens of an
#      audience of their own (audiences); the console's gitops.insecureHTTPHosts and
#      the CI's CI_INSECURE_HTTP_HOSTS (none by default: the CI is over https at
#      CI_FORGEJO_URL) name exact hosts, no glob (the CI's warned of); the
#      CI's workflow is written (okdp-gitops workflow --for output, which refuses an
#      http:// host not in CI_INSECURE_HTTP_HOSTS); projects.yaml lists the projects
#      of projects/ (split); a project of projects/ has a project.yaml (the scripts'
#      projects); the privileged projects of platform.yaml are projects of projects/
#      or optional/projects/ (a typo would confine the project it meant);
#   3. the catalog sandbox-charts holds the bootstrap (bootstrap/charts.yaml, the
#      platform's prerequisites, README step 3), which it checks itself
#      (scripts/check-bootstrap.sh); the keys of the secret store the connections
#      name are ones its init writes and the namespaces read: none under platform/,
#      <namespace>/s3/platform of a namespace of its bootstrap/openbao/s3.yaml;
#   4. the tree compiles (as scripts/compile.sh does: okdp-gitops compile, every
#      instance compiled together with its package of the catalogs, each claim bound
#      to its provider), into the output tree that scripts/configure.sh --push would
#      push (a temporary directory, or --output DIR), the control plane's
#      ServiceAccount of platform.yaml one its namespace's instances render; nothing
#      compiled is kept in the
#      layout; its errors and warnings printed as the compile reports them; with
#      --charts DIR, the compile's chart cache (okdp-gitops compile --charts DIR, which
#      pulls the upstream charts of the compiled instances there, OCI digests
#      verified), the values checked against each chart's defaults and schema;
#   5. the optional projects and instances (optional/projects/) compile too, moved
#      into projects/ (a copy of the layout), as one moves them by hand;
#   6. the kustomizations of that output build (when kustomize is installed): the
#      root's, compiled/projects, which Flux syncs, each project's, its manifests'
#      (project/), each instance's;
#   7. with --helm: every compiled instance renders with `helm template` (its umbrella
#      chart, its dependencies fetched from their repositories by helm dependency
#      build, with its instance.values.yaml): the charts' templates, which the
#      compile's chart cache does not hold (Chart.yaml, values.yaml,
#      values.schema.json only).
# The catalogs are those of catalogs.yaml, read as scripts/compile.sh reads them
# (--catalog NAME=SRC, OKDP_CATALOGS; default: the checkouts next to this repository
# at the catalog's ref, else GitHub).
#
# Usage: check.sh [--root DIR] [--output DIR] [--catalog NAME=SRC]...
#                 [--charts DIR] [--helm]
# Requires bash >= 4, yq v4, git, okdp-gitops (https://github.com/OKDP/okdp-gitops:
# make build; OKDP_GITOPS names it); optional: kustomize, helm.

set -euo pipefail
export LC_ALL=C

PROG=check
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
HELM=false
CHARTS=""
OUTPUT=""
CATALOGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --output) OUTPUT="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
    --catalog) CATALOGS+=("$2"); shift 2 ;;
    --charts) CHARTS="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
    --helm) HELM=true; shift ;;
    -h|--help) sed -n '18,76p' "$0"; exit 0 ;;
    *) echo "check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/topology.sh
source "$SCRIPTS/lib/topology.sh"
# shellcheck source=lib/forgejo.sh
source "$SCRIPTS/lib/forgejo.sh"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
step() { echo "== $*"; }
# compile_report LOG: what the compile printed on stderr (its problems, its
# warnings), indented.
compile_report() { if [[ -s "$1" ]]; then sed 's/^/   /' "$1" >&2; fi; }

work_init ""
TMP="$WORK"
OUT="${OUTPUT:-$WORK/output}"
# The flags of each compile: the chart cache, okdp-gitops compile's own.
COMPILE_ARGS=()
[[ -z "$CHARTS" ]] || COMPILE_ARGS=(--charts "$CHARTS")

# --------------------------------------------------- 1. the files the scripts read
# The scripts read these with yq, beside the compile (which reports the files of the
# tree it reads itself): the rest of this check needs them.
step "YAML syntax of the files the scripts and the engines read"
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  yq -e 'true' "$f" >/dev/null 2>&1 || [[ ! -s "$f" ]] || fail "${f#"$ROOT"/}: invalid YAML"
done < <({ printf '%s\n' "$SERVER_VALUES" "$CATALOG_FILE" "$PROJECTS_FILE" "$ROOT/platform.yaml"
  find "$ROOT/argocd" "$ROOT/flux" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort; })
if (( failures > 0 )); then
  echo "check: $failures failure(s), the files the scripts read do not parse" >&2
  exit 1
fi

# ------------------------------------------------------------- the catalogs
step "catalogs"
catalog_sources_init "${CATALOGS[@]}"
catalogs_resolve
# A branch or a tag moves: what the sandbox reads, and the bootstrap runs, would be
# whatever it holds then (scripts/bootstrap.sh refuses one read from GitHub).
while IFS=$'\t' read -r name _ ref; do
  catalog_ref_is_commit "$ref" && continue
  runs=""
  [[ "$name" != "$BOOTSTRAP_CATALOG" ]] || runs=", its bootstrap/ scripts run with cluster-admin (scripts/bootstrap.sh refuses it from GitHub)"
  echo "   warning: catalogs.yaml: catalog $name at ref '$ref', not a commit hash: it moves, the sandbox reads what it holds then$runs; pin a commit (scripts/bump-catalogs.sh)"
done < <(catalog_list)

# --------------------------------------------------- 2. the sandbox's own files
step "topology ($(topology_current))"
topology="$(topology_current)"
if ! one_of "$topology" "${TOPOLOGIES[@]}"; then
  fail "${SERVER_VALUES#"$ROOT"/}: no gitops.topology (the mono topology, one deployments repository, is gone): scripts/configure.sh --topology io|split"
  topology=io
fi
for k in repoURL branch path; do
  [[ "$(yq ".gitops | has(\"$k\")" "$SERVER_VALUES")" == false ]] \
    || fail "${SERVER_VALUES#"$ROOT"/}: gitops.$k names the single deployments repository of the removed mono topology, which the server refuses: scripts/configure.sh --topology $topology"
done
topology_matches "$topology" \
  || fail "${SERVER_VALUES#"$ROOT"/}: gitops.topology is not the sandbox's $topology topology (other repositories: an older layout's?): scripts/configure.sh --topology $topology"
if [[ "$topology" == io ]]; then
  # The trust model of io: one repository for every project.
  echo "   warning: io, a small team's: every writer of okdp/$PROJECTS_REPO writes every project, the platform's own (privileged) among them; split gives each project a repository of its own, its team's"
fi
[[ "$(entry_url)" == "$(output_url "$topology")" ]] \
  || fail "argocd/ and flux/ read $(entry_url), not the output repository of the $topology topology: scripts/configure.sh --topology $topology"
[[ -z "$(entry_prefix)" ]] \
  || fail "flux/sync.yaml: the path starts with $(entry_prefix), the output is at the root of its repository (./compiled/projects)"
[[ "$(yq 'select(.kind == "Application") | .spec.source.repoURL' "$ROOT/argocd/root.yaml")" == "$(output_url "$topology")" ]] \
  || fail "argocd/root.yaml: its source is not the output repository (okdp-gitops writes the Applications of the instances from it)"
# The AppProjects of the entry point read the output repository only; the app of
# apps of the instances writes Applications in argocd and nothing else.
for f in "$ROOT"/argocd/*.yaml; do
  [[ "$(U="$(output_url "$topology")" yq 'select(.kind == "AppProject") | .spec.sourceRepos[] | select(. != strenv(U))' "$f")" == "" ]] \
    || fail "argocd/${f##*/}: an AppProject reads another repository than the output repository"
done
[[ "$(yq -o=json -I=0 'select(.kind == "Application" and .metadata.name == "okdp.instances") | .spec.project' "$ROOT/argocd/instances.yaml")" == '"okdp.instances"' \
  && "$(yq 'select(.kind == "AppProject" and .metadata.name == "okdp.instances")' "$ROOT/argocd/instances.yaml" \
    | yq -o=json -I=0 '[.spec.destinations, (.spec.clusterResourceWhitelist // []), .spec.namespaceResourceWhitelist]')" \
    == '[[{"server":"https://kubernetes.default.svc","namespace":"argocd"}],[],[{"group":"argoproj.io","kind":"Application"}]]' ]] \
  || fail "argocd/instances.yaml: the Application okdp.instances is not of the AppProject okdp.instances, or that AppProject allows more than Applications in argocd"
# Argo CD's roles: the platform's administrators (global.okdp.access.admins) admins,
# no default role for the others (the projects' AppProject roles alone).
rbac="$ROOT/argocd/bootstrap/argocd-rbac-cm-patch.yaml"
[[ "$(yq '.data["policy.default"]' "$rbac")" == "" ]] \
  || fail "${rbac#"$ROOT"/}: policy.default gives every user a role, it must be \"\""
for g in $(yq -r '.global.okdp.access.admins[]?' "$ROOT/platform.yaml"); do
  grep -qxF "g, $g, role:admin" <(yq '.data["policy.csv"]' "$rbac") \
    || fail "${rbac#"$ROOT"/}: no \"g, $g, role:admin\" for the administrators' group $g of platform.yaml (global.okdp.access.admins)"
done
# The OIDC provider's certificate checked by every client, against the platform's CA
# bundle: a forged issuer would otherwise sign in as anyone, an administrator too.
[[ "$(yq '.global.okdp.oidc.insecureSkipVerify // false' "$ROOT/platform.yaml")" == false ]] \
  || fail "platform.yaml: global.okdp.oidc.insecureSkipVerify takes any certificate of the issuer, it must be false (the services trust global.okdp.tls.caBundleSecret)"
cm="$ROOT/argocd/bootstrap/argocd-cm-patch.yaml"
[[ "$(yq '.data["oidc.tls.insecure.skip.verify"] // "false"' "$cm")" == false ]] \
  || fail "${cm#"$ROOT"/}: oidc.tls.insecure.skip.verify takes any certificate of the issuer, it must be \"false\" (rootCA, README step 5a)"
[[ ! -f "$SERVER_VALUES" || "$(yq '.keycloak.tlsInsecure // false' "$SERVER_VALUES")" == false ]] \
  || fail "${SERVER_VALUES#"$ROOT"/}: keycloak.tlsInsecure sends the console's Keycloak credentials to any certificate, it must be false"
# The console's credentials over http:// to exact hosts only.
if [[ -f "$SERVER_VALUES" ]]; then
  while IFS= read -r h; do
    [[ -z "$h" || "$h" != *[*?[]* ]] \
      || fail "${SERVER_VALUES#"$ROOT"/}: gitops.insecureHTTPHosts $h is a glob: the console's Git token goes in clear to any host it matches, name the in-cluster Forgejo's exact host"
  done < <(yq -r '.gitops.insecureHTTPHosts[]?' "$SERVER_VALUES")
fi
# The secret store over https, its certificate checked, its tokens of an audience of
# their own: every namespace's SecretStore sends a ServiceAccount token there.
vault='.global.okdp.secrets.provider.vault'
if [[ "$(yq "$vault != null" "$ROOT/platform.yaml")" == true ]]; then
  [[ "$(yq "$vault.server // \"\"" "$ROOT/platform.yaml")" == https://* ]] \
    || fail "platform.yaml: global.okdp.secrets.provider.vault.server is not https://: the namespaces' tokens and secrets would go in clear"
  [[ "$(yq "($vault.caProvider.name // $vault.caBundle // \"\") != \"\"" "$ROOT/platform.yaml")" == true ]] \
    || fail "platform.yaml: global.okdp.secrets.provider.vault: no caProvider nor caBundle, OpenBao's certificate of the platform's CA would not be trusted"
  [[ "$(yq "($vault.auth.kubernetes.serviceAccountRef.audiences // []) | length" "$ROOT/platform.yaml")" != 0 ]] \
    || fail "platform.yaml: global.okdp.secrets.provider.vault.auth.kubernetes.serviceAccountRef.audiences is empty: the store would send a token of the API server's audience"
fi
# The workflow scripts/configure.sh --push installs in the output repository.
ci_topology_file "$topology" >"$TMP/topology.ci.yaml"
if ! forgejo_output_workflow "$TMP/ci" "$TMP/topology.ci.yaml" 2>"$TMP/.workflow.log"; then
  compile_report "$TMP/.workflow.log"
  fail "the CI's workflow (okdp-gitops workflow --for output, CI_INSECURE_HTTP_HOSTS=${CI_INSECURE_HTTP_HOSTS:-none}): its topology refused"
fi
# The catalogs the CI fetches are at https://, or at an http:// host the CI's token may
# reach (CI_INSECURE_HTTP_HOSTS): the compile refuses a credential in clear.
while IFS=$'\t' read -r cname curl cref; do
  [[ "$curl" == http://* ]] || continue
  chost="${curl#http://}"; chost="${chost%%/*}"; chost="${chost%%:*}"
  [[ ",$CI_INSECURE_HTTP_HOSTS," == *",$chost,"* ]] \
    || fail "catalogs.yaml: the catalog $cname is at $curl, over http:// to $chost, which CI_INSECURE_HTTP_HOSTS does not allow: the CI's token would not be sent (use https://, CI_FORGEJO_URL)"
done < <(catalog_list)
if [[ "$CI_INSECURE_HTTP_HOSTS" == *[*?[]* ]]; then
  echo "   warning: CI_INSECURE_HTTP_HOSTS=$CI_INSECURE_HTTP_HOSTS is a glob: the CI's token goes in clear to any host it matches, name an exact host (none by default: the CI is over https)"
fi
if [[ "$topology" == split ]]; then
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    fail "projects.yaml is missing (split topology: scripts/configure.sh --topology split)"
  else
    listed="$(yq -r '.projects[]?.name' "$PROJECTS_FILE" | sort)"
    [[ "$listed" == "$(project_names)" ]] \
      || fail "projects.yaml lists '$(tr '\n' ' ' <<<"$listed")', projects/ holds '$(project_names | tr '\n' ' ')'"
  fi
elif [[ -f "$PROJECTS_FILE" ]]; then
  fail "projects.yaml belongs to the split topology only ($topology here)"
fi

step "projects"
# The scripts take a project for a directory of projects/ with a project.yaml
# (project_names: projects.yaml, the repositories of split).
for d in "$ROOT"/projects/*/; do
  [[ -d "$d" ]] || continue
  [[ -f "$d/project.yaml" ]] \
    || fail "projects/$(basename "$d"): project.yaml is missing (the scripts' projects are the directories with one: projects.yaml, the repositories of split)"
done
# The platform's own projects: projects of the layout, or optional ones (moved into
# projects/ by hand); a name that is neither is a typo, which would confine the
# project it meant.
if [[ -f "$ROOT/platform.yaml" ]]; then
  for p in $(yq -r '.global.okdp.policy.privileged[]?' "$ROOT/platform.yaml"); do
    [[ -f "$ROOT/projects/$p/project.yaml" || -f "$ROOT/optional/projects/$p/project.yaml" ]] \
      || fail "platform.yaml: global.okdp.policy.privileged: $p is no project of projects/ or optional/projects/"
  done
fi

# The initial access tokens of DCR: the bootstrap mints one per namespace of
# DCR_NAMESPACES (lib/common.sh, scripts/bootstrap.sh); a namespace whose secrets
# instance (the service local-secrets-provider of the project) has no entry
# okdp-dcr-token reading <namespace>/keycloak/dcr-token gets no Secret
# okdp-dcr-token: every oidc-dcr Job of the namespace fails.
if [[ -f "$ROOT/platform.yaml" && "$(yq '.global.okdp.oidc.clientProvisioning // ""' "$ROOT/platform.yaml")" == dcr \
  && "$(yq '.global.okdp.oidc.dcr.authMethod // ""' "$ROOT/platform.yaml")" == initialAccessToken ]]; then
  for ns in $DCR_NAMESPACES; do
    found=false
    for i in "$ROOT/projects/$ns"/instances/*/instance.yaml; do
      [[ -f "$i" && "$(yq '.service // ""' "$i")" == local-secrets-provider ]] || continue
      NS="$ns" yq -e '(.secrets // [])[] | select(.name == "okdp-dcr-token" and .remoteKey == strenv(NS) + "/keycloak/dcr-token")' \
        "$(dirname "$i")/config.yaml" >/dev/null 2>&1 && found=true
    done
    $found || echo "   warning: DCR_NAMESPACES: $ns has no secrets instance (local-secrets-provider) with an entry okdp-dcr-token reading $ns/keycloak/dcr-token: the bootstrap mints its initial access token, nothing reads it and the oidc-dcr Jobs of $ns fail"
  done
fi

# -------------------------------------------------------------- 3. bootstrap
# The bootstrap is the catalog sandbox-charts' (bootstrap/), checked there
# (scripts/check-bootstrap.sh): here, that the catalog read holds one.
step "bootstrap (bootstrap/ of the catalog $BOOTSTRAP_CATALOG)"
if [[ -z "${CATALOG_DIRS[$BOOTSTRAP_CATALOG]:-}" ]]; then
  fail "catalogs.yaml: no catalog $BOOTSTRAP_CATALOG, whose bootstrap/ holds the platform's prerequisites"
elif [[ ! -f "${CATALOG_DIRS[$BOOTSTRAP_CATALOG]}/bootstrap/charts.yaml" ]]; then
  fail "catalog $BOOTSTRAP_CATALOG: no bootstrap/charts.yaml"
else
  # The keys of the platform's secret store the connections name are the ones the
  # bootstrap writes and the namespaces read (its bootstrap/openbao/init.sh): no
  # namespace reads platform/, and the platform's S3 identity is under
  # <namespace>/s3/platform of the namespaces of bootstrap/openbao/s3.yaml only.
  s3_consumers="${CATALOG_DIRS[$BOOTSTRAP_CATALOG]}/bootstrap/openbao/s3.yaml"
  while IFS= read -r f; do
    while IFS= read -r key; do
      case "$key" in
        platform/*)
          fail "${f#"$ROOT"/}: secretRef.remoteKey $key: no namespace reads platform/ in the platform's secret store (bootstrap/openbao/init.sh of $BOOTSTRAP_CATALOG): a key of the namespaces that read it" ;;
        */s3/platform)
          if ! { [[ -f "$s3_consumers" ]] \
                 && NS="${key%%/*}" yq -e '[(.namespaces // [])[] | select(. == strenv(NS))] | length > 0' "$s3_consumers" >/dev/null 2>&1; }; then
            fail "${f#"$ROOT"/}: secretRef.remoteKey $key: the bootstrap writes the platform's S3 identity there for the namespaces of bootstrap/openbao/s3.yaml of $BOOTSTRAP_CATALOG only, ${key%%/*} is none"
          fi ;;
      esac
    done < <(yq -r '.connections // {} | to_entries[] | .value.secretRef.remoteKey // ""' "$f" | grep -v '^$' || true)
  done < <(find "$ROOT/platform.yaml" "$ROOT/projects" "$ROOT/optional" \
    \( -name platform.yaml -o -name project.yaml -o -name connections.yaml \) -type f 2>/dev/null | sort)
fi

# ------------------------------------------------------------- 4. compile
step "the tree compiles (okdp-gitops compile, into ${OUTPUT:-a temporary output tree}${CHARTS:+, the charts cached in $CHARTS})"
compiled=false
if ! command -v "${OKDP_GITOPS:-okdp-gitops}" >/dev/null; then
  fail "okdp-gitops is required (https://github.com/OKDP/okdp-gitops: make build; or set OKDP_GITOPS)"
elif ! layout_compile "$OUT" "${COMPILE_ARGS[@]}" >"$TMP/.compile.out" 2>"$TMP/.compile.log"; then
  compile_report "$TMP/.compile.log"
  fail "the tree does not compile (okdp-gitops compile, above)"
else
  compiled=true
  compile_report "$TMP/.compile.log"
  echo "   $(find "$OUT/compiled" -type f | wc -l) files in compiled/"
  # The control plane's ServiceAccount of platform.yaml, which the compiler binds in
  # each project's namespace, is the one the console's package renders.
  sa_ns="$(yq -r '.global.okdp.controlPlane.serviceAccount.namespace // ""' "$ROOT/platform.yaml")"
  sa_name="$(yq -r '.global.okdp.controlPlane.serviceAccount.name // ""' "$ROOT/platform.yaml")"
  if [[ -n "$sa_name" ]]; then
    rendered="$(find "$OUT/compiled/projects/$sa_ns/instances" -name okdp.objects.yaml -exec \
      yq -r 'select(.kind == "ServiceAccount") | .metadata.name' {} + 2>/dev/null)"
    grep -qxF "$sa_name" <<<"$rendered" \
      || fail "platform.yaml: global.okdp.controlPlane.serviceAccount $sa_ns/$sa_name is no ServiceAccount the instances of $sa_ns render ($(tr '\n' ' ' <<<"$rendered")): the server would get no rights in the projects' namespaces"
  fi
fi

# --------------------------------------------------- 5. the optional projects
# optional/projects/ holds projects and instances in the layout of projects/, moved
# into place by hand: a copy of the layout with them moved compiles too.
if [[ -d "$ROOT/optional/projects" ]]; then
  if ! $compiled; then
    step "the optional projects compile: skipped (the tree does not compile)"
  else
    step "the optional projects compile, moved into projects/ (a copy of the layout)"
    opt="$TMP/with-optional"
    rm -rf "$opt"; cp -R "$ROOT" "$opt"; rm -rf "$opt/optional" "$opt/.git"
    while IFS= read -r f; do
      rel="${f#"$ROOT"/optional/}"
      if [[ -e "$opt/$rel" ]]; then
        fail "optional/$rel: $rel exists, the optional file cannot be moved into place"
        continue
      fi
      mkdir -p "$(dirname "$opt/$rel")"; cp "$f" "$opt/$rel"
    done < <(find "$ROOT/optional/projects" -type f | sort)
    if ! ROOT="$opt" layout_compile "$TMP/with-optional.output" "${COMPILE_ARGS[@]}" >"$TMP/.optional.out" 2>"$TMP/.optional.log"; then
      compile_report "$TMP/.optional.log"
      fail "the tree with optional/projects/ moved into projects/ does not compile (okdp-gitops compile, above)"
    else
      compile_report "$TMP/.optional.log"
      echo "   $(find "$ROOT/optional/projects" -path '*/instances/*/instance.yaml' | wc -l) optional instances"
    fi
  fi
fi

# ------------------------------------------------------------ 6. kustomize
if ! $compiled; then
  step "kustomize build: skipped (nothing compiled)"
elif command -v kustomize >/dev/null; then
  step "kustomize build"
  dirs=("$OUT/compiled/projects")
  for d in "$OUT"/compiled/projects/*/ "$OUT"/compiled/projects/*/project/ "$OUT"/compiled/projects/*/instances/*/; do
    [[ -f "$d/kustomization.yaml" ]] && dirs+=("${d%/}")
  done
  for d in "${dirs[@]}"; do
    kustomize build "$d" >/dev/null 2>"$TMP/.kustomize.log" \
      || { fail "kustomize build ${d#"$OUT"/}"; sed 's/^/   /' "$TMP/.kustomize.log"; }
  done
  echo "   ${#dirs[@]} kustomizations"
else
  step "kustomize build: skipped (kustomize not installed)"
fi

# ----------------------------------------------------------------- 7. helm
if $HELM; then
  command -v helm >/dev/null || fail "--helm needs helm"
fi
if $HELM && ! $compiled; then
  step "helm template of the compiled instances: skipped (nothing compiled)"
elif $HELM; then
  step "helm template of the compiled instances"
  while IFS= read -r inst; do
    dir="$(dirname "$inst")"; n="${dir##*/}"; p="$(basename "$(dirname "$(dirname "$dir")")")"
    r="$p-$n"; out="$OUT/compiled/projects/$p/instances/$r"; rel="projects/$p/instances/$n"
    if [[ ! -f "$out/Chart.yaml" ]]; then
      fail "helm template $rel: no compiled umbrella chart (compiled/projects/$p/instances/$r/Chart.yaml)"
      continue
    fi
    # The umbrella, its dependencies fetched from their repositories.
    chart="$TMP/umbrella/$r"
    rm -rf "$chart"; mkdir -p "$chart"; cp -R "$out/." "$chart"; rm -rf "$chart/charts" "$chart/Chart.lock"
    helm dependency build "$chart" >"$TMP/.helm.log" 2>&1 \
      || { fail "helm dependency build $rel"; grep -v 'failed to load plugins' "$TMP/.helm.log" | sed 's/^/   /'; continue; }
    if helm template "$r" "$chart" -n "$p" -f "$out/instance.values.yaml" >"$TMP/.helm.out" 2>"$TMP/.helm.log"; then
      echo "   ok $rel ($(grep -c '^kind:' "$TMP/.helm.out") objects)"
    else
      fail "helm template $rel"; grep -v 'failed to load plugins' "$TMP/.helm.log" | sed 's/^/   /'
    fi
  done < <(find "$ROOT/projects" -path '*/instances/*/instance.yaml' 2>/dev/null | sort)
fi

if (( failures > 0 )); then
  echo "check: $failures failure(s)" >&2
  exit 1
fi
echo "check: OK"
