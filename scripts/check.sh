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

# CI check of the deployments layout (see gitops/README.md).
#
#   1. every YAML file parses;
#   2. the shapes: platform.yaml (its privileged projects, projects of the layout),
#      catalogs.yaml (its repositories and its menu), projects.yaml (the split
#      topology), each project's project.yaml, each
#      instance's instance.yaml (a package of the catalogs) and config.yaml; the
#      control plane server names the sandbox's io or split topology (gitops.topology;
#      no single repository, mono is gone; io warned of: every writer of the projects
#      repository writes every project); flux/ and argocd/ read the output repository
#      of the topology; the CI's topology
#      reaches http:// on the hosts of CI_INSECURE_HTTP_HOSTS only; the connections
#      (platform.yaml, project.yaml, connections.yaml) match their contract schema,
#      from the contracts/ of the catalogs (one contract in two catalogs must be the
#      same file);
#   3. the catalog sandbox-charts holds the bootstrap (bootstrap/charts.yaml, the
#      platform's prerequisites, README step 3), which it checks itself
#      (scripts/check-bootstrap.sh);
#   4. the tree compiles (as scripts/compile.sh does: okdp-gitops compile, every
#      instance compiled together with its package of the catalogs, each claim bound
#      to its provider), into the output tree that scripts/configure.sh --push would
#      push (a temporary directory, or --output DIR); nothing compiled is kept in the
#      layout;
#   5. the kustomizations of that output build (when kustomize is installed): the
#      root's, compiled/projects, which Flux syncs, each project's, its manifests'
#      (project/), each instance's;
#   6. with --helm: every compiled instance renders with `helm template` (its umbrella
#      chart, its dependencies from the --charts DIR cache, scripts/pull-charts.sh,
#      else helm dependency build, with its instance.values.yaml), which also checks
#      its values against each chart's values.schema.json.
# The catalogs are those of catalogs.yaml, read as scripts/compile.sh reads them
# (--catalog NAME=SRC, OKDP_CATALOGS; default: the checkouts next to this repository
# at the catalog's ref, else GitHub).
#
# Usage: check.sh [--root DIR] [--output DIR] [--catalog NAME=SRC]...
#                 [--charts DIR] [--helm]
# Requires bash >= 4, yq v4, jq, git, okdp-gitops (https://github.com/OKDP/okdp-gitops:
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
    --charts) CHARTS="$(cd "$2" && pwd)"; shift 2 ;;
    --helm) HELM=true; shift ;;
    -h|--help) sed -n '18,55p' "$0"; exit 0 ;;
    *) echo "check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/topology.sh
source "$SCRIPTS/lib/topology.sh"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
step() { echo "== $*"; }
dns_label() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 63 ]]; }
# keys FILE [PATH]: the keys of the map at PATH of FILE, joined by commas.
keys() { yq "${2:-.} | [keys[]] | join(\",\")" "$1"; }
# only FILE PATH ALLOWED...: fails for each key of the map at PATH not in ALLOWED.
only() {
  local f="$1" path="$2" k pre=""; shift 2
  [[ "$path" == "." ]] || pre="${path#.}."
  [[ "$(yq "$path | tag" "$f")" == "!!map" ]] || return 0
  for k in $(yq -r "$path | keys[]" "$f"); do
    one_of "$k" "$@" || fail "${f#"$ROOT"/}: $pre$k: unknown key (${*})"
  done
}

work_init ""
TMP="$WORK"
OUT="${OUTPUT:-$WORK/output}"

# ------------------------------------------------------------------ 1. YAML
step "YAML syntax"
while IFS= read -r f; do
  yq -e 'true' "$f" >/dev/null 2>&1 || [[ ! -s "$f" ]] || fail "${f#"$ROOT"/}: invalid YAML"
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/compiled" -prune \
  -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort)

# ------------------------------------------------------------- the catalogs
step "catalogs"
catalog_sources_init "${CATALOGS[@]}"
catalogs_resolve
# Contracts: the union of the catalogs' contracts/, the same file wherever repeated.
declare -A CONTRACTS=()
for name in $(printf '%s\n' "${!CATALOG_DIRS[@]}" | sort); do
  for f in "${CATALOG_DIRS[$name]}"/contracts/*.schema.json; do
    [[ -f "$f" ]] || continue
    c="${f##*/}"; c="${c%.schema.json}"
    if [[ -n "${CONTRACTS[$c]:-}" ]] && ! cmp -s "${CONTRACTS[$c]}" "$f"; then
      fail "contract $c differs between the catalogs (${CONTRACTS[$c]} and $f)"
    fi
    CONTRACTS[$c]="$f"
  done
done
echo "   contracts: $(printf '%s\n' "${!CONTRACTS[@]}" | sort | tr '\n' ' ')"
# catalog_package SERVICE [VERSION]: the catalog holding catalog/SERVICE[/VERSION].
catalog_package() {
  local name
  for name in "${!CATALOG_DIRS[@]}"; do
    if [[ -d "${CATALOG_DIRS[$name]}/catalog/$1${2:+/$2}" ]]; then echo "$name"; return 0; fi
  done
  return 1
}

# ----------------------------------------------------------------- 2. shapes
step "platform.yaml, catalogs.yaml"
pv="$ROOT/platform.yaml"
if [[ ! -f "$pv" ]]; then
  fail "platform.yaml is missing"
else
  only "$pv" "." global connections
  [[ "$(yq '.global.okdp | tag' "$pv")" == "!!map" ]] || fail "platform.yaml: global.okdp is required"
  [[ "$(yq '.global.okdp | has("certificateIssuers")' "$pv")" == "false" ]] \
    || fail "platform.yaml: global.okdp.certificateIssuers is gone: global.okdp.tls.clusterIssuer"
  [[ "$(yq '.global.okdp | has("serviceCatalog")' "$pv")" == "false" ]] \
    || fail "platform.yaml: serviceCatalog belongs in catalogs.yaml"
  # The platform's own projects: projects of the layout, or optional ones (moved into
  # projects/ by hand); a name that is neither is a typo, which would confine the
  # project it meant.
  for p in $(yq -r '.global.okdp.policy.privileged[]?' "$pv"); do
    [[ -f "$ROOT/projects/$p/project.yaml" || -f "$ROOT/optional/projects/$p/project.yaml" ]] \
      || fail "platform.yaml: global.okdp.policy.privileged: $p is no project of projects/ or optional/projects/"
  done
fi
cat="$CATALOG_FILE"
if [[ ! -f "$cat" ]]; then
  fail "catalogs.yaml is missing"
else
  only "$cat" "." repositories categories
  [[ "$(yq '.repositories | tag' "$cat")" == "!!seq" ]] || fail "catalogs.yaml: repositories must be a list"
  bad="$(yq '[.repositories[]? | select((.name | tag) != "!!str" or (.url | tag) != "!!str" or (.ref | tag) != "!!str")] | length' "$cat")"
  [[ "$bad" == "0" ]] || fail "catalogs.yaml: every repository needs name, url and ref (strings)"
  dup="$(yq -r '[.repositories[]?.name] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$cat")"
  [[ -z "$dup" ]] || fail "catalogs.yaml: repositories named twice: $dup"
  [[ "$(yq '.categories | tag' "$cat")" == "!!seq" ]] || fail "catalogs.yaml: categories must be a list"
  bad="$(yq '[.categories[] | select((.title | tag) != "!!str" or (.services | tag) != "!!seq")] | length' "$cat")"
  [[ "$bad" == "0" ]] || fail "catalogs.yaml: every category needs a title and a services list"
  bad="$(yq '[.categories[].services[] | select((.name | tag) != "!!str" or has("versions") or has("repository") or (has("default") and (.default | tag) != "!!str"))] | length' "$cat")"
  [[ "$bad" == "0" ]] || fail "catalogs.yaml: a service has a name and maybe a default version (a string); its versions are its catalog's directories"
  while IFS=$'\t' read -r s def; do
    if ! catalog_package "$s" >/dev/null; then
      fail "catalogs.yaml: service $s is in no catalog"
    elif [[ -n "$def" ]] && ! catalog_package "$s" "$def" >/dev/null; then
      fail "catalogs.yaml: service $s has no version $def"
    fi
  done < <(yq -r '.categories[].services[] | [.name, .default // ""] | @tsv' "$cat")
fi

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
for url in $(ci_http_refused "$topology" | sort -u); do
  fail "the CI's topology: $url is http://, its host not in CI_INSECURE_HTTP_HOSTS ($CI_INSECURE_HTTP_HOSTS): okdp-gitops workflow would refuse it, the CI's token would go in clear"
done
if [[ "$topology" == split ]]; then
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    fail "projects.yaml is missing (split topology: scripts/configure.sh --topology split)"
  else
    listed="$(yq -r '.projects[]?.name' "$PROJECTS_FILE" | sort)"
    for p in $listed; do
      dns_label "$p" || fail "projects.yaml: invalid project name '$p'"
    done
    [[ "$listed" == "$(project_names)" ]] \
      || fail "projects.yaml lists '$(tr '\n' ' ' <<<"$listed")', projects/ holds '$(project_names | tr '\n' ' ')'"
  fi
elif [[ -f "$PROJECTS_FILE" ]]; then
  fail "projects.yaml belongs to the split topology only ($topology here)"
fi

step "projects and instances"
# A project is a directory of projects/ with a project.yaml; its instances are its
# directories of instances/. optional/ holds projects and instances in the same
# layout, moved into place by hand.
declare -A RELEASES=()
while IFS= read -r d; do
  rel="${d#"$ROOT"/}"; p="${d##*/}"
  dns_label "$p" || fail "$rel: a project's name is a DNS label"
  if [[ "$rel" != optional/* || -f "$d/project.yaml" ]]; then
    [[ -f "$d/project.yaml" ]] || fail "$rel: project.yaml is missing (a project is a directory with a project.yaml)"
    only "$d/project.yaml" "." description global connections claims
    [[ "$(yq '.description | tag' "$d/project.yaml")" =~ ^!!(str|null)$ ]] \
      || fail "$rel/project.yaml: description is a string, the project's (quote one that holds \": \")"
  fi
  for i in "$d"/instances/*/; do
    [[ -d "$i" ]] || continue
    i="${i%/}"; irel="${i#"$ROOT"/}"; n="${i##*/}"
    dns_label "$n" || fail "$irel: an instance's name is a DNS label"
    r="$p-$n"
    (( ${#r} <= 53 )) || fail "$irel: its release $r is longer than 53 characters"
    if [[ "$rel" != optional/* ]]; then
      [[ -z "${RELEASES[$r]:-}" ]] || fail "$irel: its release $r is also ${RELEASES[$r]}'s"
      RELEASES[$r]="$irel"
    fi
    f="$i/instance.yaml"
    if [[ ! -f "$f" ]]; then fail "$irel: instance.yaml is missing"; continue; fi
    case "$(yq '[keys[]] | sort | join(",")' "$f")" in
      service,version|claimers,service,version) ;;
      *) fail "$irel/instance.yaml: the keys are service and version, and claimers for a provider, nothing else" ;;
    esac
    # A provider's consent: the namespaces that may claim of it, or "*".
    if [[ "$(yq 'has("claimers")' "$f")" == true ]]; then
      if [[ "$(yq '.claimers | tag' "$f")" != "!!seq" ]]; then
        fail "$irel/instance.yaml: claimers is a list of namespaces, or [\"*\"]"
      else
        while IFS= read -r c; do
          [[ "$c" == "*" ]] || dns_label "$c" || fail "$irel/instance.yaml: claimers: '$c' is not a namespace name, nor \"*\""
        done < <(yq -r '.claimers[]' "$f")
      fi
    fi
    [[ "$(yq '.service | tag' "$f")" == "!!str" && "$(yq '.version | tag' "$f")" == "!!str" ]] \
      || fail "$irel/instance.yaml: service and version are strings (quote a version such as \"6.10\")"
    service="$(yq '.service' "$f")"; version="$(yq '.version' "$f")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][-0-9A-Za-z.]*)?$ ]] || fail "$irel/instance.yaml: version $version is not an exact version"
    if [[ ${#CATALOG_DIRS[@]} -gt 0 ]] && ! catalog_package "$service" "$version" >/dev/null; then
      fail "$irel/instance.yaml: no package $service $version in the catalogs (catalog/$service/$version/)"
    fi
    if [[ -f "$i/config.yaml" ]]; then
      for k in global connections claims; do
        [[ "$(yq "has(\"$k\")" "$i/config.yaml")" == false ]] \
          || fail "$irel/config.yaml: $k is the context's (platform.yaml, project.yaml, connections.yaml), not an instance value"
      done
    fi
    if [[ -f "$i/connections.yaml" ]]; then only "$i/connections.yaml" "." connections; fi
    for x in "$i"/*; do
      case "${x##*/}" in
        instance.yaml|config.yaml|connections.yaml) ;;
        *) fail "$irel: ${x##*/}: not a file of an instance (instance.yaml, config.yaml, connections.yaml)" ;;
      esac
    done
  done
done < <(find "$ROOT/projects" "$ROOT/optional/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

step "connections (platform.yaml, project.yaml, connections.yaml)"
# check_connection FILE NAME: the connection connections.NAME of FILE against its
# contract: its fields known (description aside), no secret field, the required
# non-secret ones present, its credentials a Secret (secretRef.name) or a key of the
# platform's secret store (secretRef.remoteKey) when the contract has secret fields.
check_connection() {
  local f="$1" c="$2" rel contract schema fields problems m
  rel="${f#"$ROOT"/}: connections.$c"
  dns_label "$c" || fail "$rel: a connection's name is a DNS label"
  contract="$(yq ".connections[\"$c\"].contract" "$f")"
  schema="${CONTRACTS[$contract]:-}"
  [[ -n "$schema" ]] || { fail "$rel: contract '$contract' is in no catalog's contracts/"; return; }
  if [[ "$(jq '[.properties[]? | select(.["x-okdp-secret"] == true)] | length' "$schema")" != "0" ]]; then
    case "$(yq ".connections[\"$c\"].secretRef | [(.name | tag), (.remoteKey | tag)] | join(\",\")" "$f")" in
      '!!str,!!null'|'!!null,!!str') ;;
      *) fail "$rel: secretRef: name (a Secret of the namespace) or remoteKey (a key of the platform's secret store), one of them" ;;
    esac
    if [[ "$(yq ".connections[\"$c\"].secretRef | has(\"remoteKey\")" "$f")" == true \
      && "$(yq '.global.okdp.secrets.store // ""' "$pv")" == "" ]]; then
      fail "$rel: secretRef.remoteKey: the platform names no secret store (global.okdp.secrets.store)"
    fi
  fi
  fields="$(yq -o=json ".connections[\"$c\"] | del(.contract) | del(.description) | del(.secretRef)" "$f")"
  problems="$(jq -rn --argjson v "$fields" --slurpfile s "$schema" '
    ($s[0].properties // {}) as $props
    | [ ($v | keys[]) as $k
        | if ($props | has($k)) | not then "unknown field \($k)"
          elif $props[$k]["x-okdp-secret"] == true then "secret field \($k) must be in the Secret, not here"
          else empty end ]
      + [ ($s[0].required // [])[] as $r
          | select(($props[$r]["x-okdp-secret"] // false) == false)
          | select(($v | has($r)) | not) | "missing required field \($r)" ]
    | .[]')"
  while IFS= read -r m; do [[ -z "$m" ]] || fail "$rel: $m"; done <<<"$problems"
}
while IFS= read -r f; do
  [[ "$(yq '.connections | tag' "$f")" == "!!map" ]] || continue
  for c in $(yq -r '.connections | keys[]' "$f"); do check_connection "$f" "$c"; done
done < <({ echo "$pv"; find "$ROOT/projects" "$ROOT/optional/projects" \( -name project.yaml -o -name connections.yaml \) 2>/dev/null | sort; })

# -------------------------------------------------------------- 3. bootstrap
# The bootstrap is the catalog sandbox-charts' (bootstrap/), checked there
# (scripts/check-bootstrap.sh): here, that the catalog read holds one.
step "bootstrap (bootstrap/ of the catalog $BOOTSTRAP_CATALOG)"
if [[ -z "${CATALOG_DIRS[$BOOTSTRAP_CATALOG]:-}" ]]; then
  fail "catalogs.yaml: no catalog $BOOTSTRAP_CATALOG, whose bootstrap/ holds the platform's prerequisites"
elif [[ ! -f "${CATALOG_DIRS[$BOOTSTRAP_CATALOG]}/bootstrap/charts.yaml" ]]; then
  fail "catalog $BOOTSTRAP_CATALOG: no bootstrap/charts.yaml"
fi

# ------------------------------------------------------------- 4. compile
step "the tree compiles (okdp-gitops compile, into ${OUTPUT:-a temporary output tree})"
compiled=false
if ! command -v "${OKDP_GITOPS:-okdp-gitops}" >/dev/null; then
  fail "okdp-gitops is required (https://github.com/OKDP/okdp-gitops: make build; or set OKDP_GITOPS)"
elif ! layout_compile "$OUT" >"$TMP/.compile.log" 2>&1; then
  sed 's/^/   /' "$TMP/.compile.log"
  fail "the tree does not compile"
else
  compiled=true
  echo "   $(find "$OUT/compiled" -type f | wc -l) files in compiled/"
fi

# ------------------------------------------------------------ 5. kustomize
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

# ----------------------------------------------------------------- 6. helm
# cached REPOSITORY NAME VERSION: the chart in the --charts cache (the layout of
# okdp-compiler's chart cache: <repository without scheme>/<name>-<version>/<name>).
cached() {
  local d="$CHARTS/${1#*://}"; d="${d%/}/$2-$3/$2"
  [[ -n "$CHARTS" && -f "$d/Chart.yaml" ]] && echo "$d"
}

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
    # The umbrella, its dependencies from the cache or their repositories.
    chart="$TMP/umbrella/$r"
    rm -rf "$chart"; mkdir -p "$chart"; cp -R "$out/." "$chart"; rm -rf "$chart/charts" "$chart/Chart.lock"
    missing=false
    while IFS=$'\t' read -r repo dep version; do
      if src="$(cached "$repo" "$dep" "$version")"; then
        mkdir -p "$chart/charts"; rm -rf "$chart/charts/$dep-$version"; cp -R "$src" "$chart/charts/$dep-$version"
      else
        missing=true
      fi
    done < <(yq -r '.dependencies[]? | [.repository, .name, .version] | @tsv' "$out/Chart.yaml")
    if $missing; then
      rm -rf "$chart/charts"
      helm dependency build "$chart" >"$TMP/.helm.log" 2>&1 \
        || { fail "helm dependency build $rel"; grep -v 'failed to load plugins' "$TMP/.helm.log" | sed 's/^/   /'; continue; }
    fi
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
