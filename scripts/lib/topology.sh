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

# Sourced by the scripts in scripts/: the topology of the deployments
# repositories, the service catalogs, and the compile of the layout.
#
# The layout (ROOT, gitops/ of this repository) holds what bootstraps the sandbox: the
# tree, okdp-compiler's (platform.yaml, projects/<p>/), okdp-gitops' files beside it
# (catalogs.yaml, projects.yaml in split) and the engines' entry points (argocd/,
# flux/). The compiled tree is never here: a compile writes it into an output
# directory, and scripts/configure.sh --push into the output repository on Forgejo. The
# topology says which Forgejo repository each part lives in (gitops/README.md,
# "Topologies"):
#   mono   one deployments repository, gitops.repoURL of the control plane server
#          (okdp-deployments): platform.yaml, catalogs.yaml, projects/, compiled/,
#          argocd/;
#   io     okdp-input (platform.yaml, catalogs.yaml, projects/) and okdp-output
#          (compiled/, argocd/);
#   split  okdp-platform (platform.yaml, catalogs.yaml, projects.yaml at its root),
#          okdp-project-<p> (projects/<p>/ at its root; the projects listed in
#          projects.yaml) and okdp-output.
# It is kept in the values of the control plane server: no gitops.topology is mono;
# gitops.topology is the topology file of the server (GITOPS_CONFIG) for io and split.
# Each part is at the root of its repository. Argo CD and Flux read the output
# repository only: argocd/ and flux/ name its URL.
#
# Before sourcing: PROG (the script's name, for messages), ROOT (the layout), SCRIPTS
# (this scripts directory). Requires bash >= 4, yq v4, and git for the catalogs.

# shellcheck disable=SC2034 # used by the scripts that source this file
TOPOLOGIES=(mono io split)
INPUT_REPO=okdp-input
OUTPUT_REPO=okdp-output
PLATFORM_REPO=okdp-platform
PROJECT_REPO_PREFIX=okdp-project-
FORGEJO_TOKEN_SECRET=okdp-forgejo-token

# The instances the scripts configure: projects/<namespace>/instances/<name>.
SERVER_NAMESPACE=okdp-system
SERVER_VALUES="$ROOT/projects/$SERVER_NAMESPACE/instances/okdp-control-plane-server/config.yaml"
# The CI runner of the sources, the bootstrap's (bootstrap/forgejo-runner of
# BOOTSTRAP_CATALOG): its registration Secret (registrationSecret of its values) and
# its Deployment, the release forgejo-runner.
RUNNER_NAMESPACE=forgejo
RUNNER_DEPLOYMENT=forgejo-runner
# The catalog whose bootstrap/ holds the platform's prerequisites (their values,
# manifests, init scripts and charts.yaml), read with the catalogs (bootstrap_resolve).
BOOTSTRAP_CATALOG=sandbox-charts
# okdp-gitops' files, beside platform.yaml.
CATALOG_FILE="$ROOT/catalogs.yaml"
PROJECTS_FILE="$ROOT/projects.yaml"
# This repository: the catalogs default to checkouts next to it.
SANDBOX_TOP="$(git -C "$SCRIPTS" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPTS/.." && pwd))"

die() { echo "$PROG: $*" >&2; exit 1; }

# on_exit COMMAND: run COMMAND when the script exits (after the ones registered before).
ON_EXIT=()
run_on_exit() {
  local c
  for c in "${ON_EXIT[@]}"; do eval "$c"; done
}
on_exit() {
  ON_EXIT+=("$1")
  trap run_on_exit EXIT
}

# work_init [DIR]: WORK, the directory of the catalogs read at their ref, the local
# topology file, the compiled output and the parts pushed to Forgejo; a temporary one,
# removed at exit, unless DIR is given.
work_init() {
  if [[ -n "${1:-}" ]]; then
    mkdir -p "$1"; WORK="$(cd "$1" && pwd)"
  else
    WORK="$(mktemp -d)"
    # shellcheck disable=SC2016 # expanded at exit
    on_exit 'rm -rf "$WORK"'
  fi
}

one_of() { # value choices...
  local v="$1"; shift
  local c; for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  return 1
}

# ------------------------------------------------------------------ topology

# The mono deployments repository (gitops.repoURL), the layout at its root.
mono_url() { yq '.gitops.repoURL // ""' "$SERVER_VALUES"; }
mono_repo() { local u; u="$(mono_url)"; u="${u##*/}"; echo "${u%.git}"; }
mono_check() {
  [[ -z "$(yq '.gitops.path // ""' "$SERVER_VALUES" | tr -d /)" ]] \
    || die "gitops.path (${SERVER_VALUES#"$ROOT"/}): the layout is at the root of its repositories, remove it"
}

# The in-cluster Forgejo (http://<host>:<port>) and its organization, from
# gitops.repoURL (<forgejo>/<organization>/<repository>.git).
forgejo_cluster_url() {
  local u; u="$(mono_url)"
  [[ "$u" =~ ^([a-z]+://[^/]+)/([^/]+)/[^/]+$ ]] \
    || die "gitops.repoURL '$u' (${SERVER_VALUES#"$ROOT"/}): not <forgejo>/<organization>/<repository>.git"
  echo "${BASH_REMATCH[1]}"
}
forgejo_owner() {
  local u; u="$(mono_url)"
  [[ "$u" =~ ^([a-z]+://[^/]+)/([^/]+)/[^/]+$ ]] \
    || die "gitops.repoURL '$u' (${SERVER_VALUES#"$ROOT"/}): not <forgejo>/<organization>/<repository>.git"
  echo "${BASH_REMATCH[2]}"
}

# topology_current: mono, io or split, from gitops.topology of the server's values.
topology_current() {
  if [[ "$(yq '.gitops.topology | tag' "$SERVER_VALUES")" == "!!null" ]]; then
    echo mono
  elif [[ "$(yq '.gitops.topology.projects.url // ""' "$SERVER_VALUES")" == *"{project}"* ]]; then
    echo split
  else
    echo io
  fi
}

# topology_file mono|io|split: the topology file of the server (GITOPS_CONFIG, io and
# split) and of okdp-gitops --config (the CI's, ci_topology_file), the repositories on
# the in-cluster Forgejo.
topology_file() {
  local base owner
  base="$(forgejo_cluster_url)"; owner="$(forgejo_owner)"
  case "$1" in
    mono)
      cat <<EOF
platform: {url: "$(mono_url)", branch: main, path: ""}
projects: {url: "$(mono_url)", branch: main, path: "projects/{project}"}
output: {url: "$(mono_url)", branch: main, path: ""}
EOF
      ;;
    io)
      cat <<EOF
platform: {url: "$base/$owner/$INPUT_REPO.git", branch: main, path: ""}
projects: {url: "$base/$owner/$INPUT_REPO.git", branch: main, path: "projects/{project}"}
output: {url: "$base/$owner/$OUTPUT_REPO.git", branch: main, path: ""}
EOF
      ;;
    split)
      cat <<EOF
platform: {url: "$base/$owner/$PLATFORM_REPO.git", branch: main, path: ""}
projects: {url: "$base/$owner/$PROJECT_REPO_PREFIX{project}.git", branch: main, path: ""}
output: {url: "$base/$owner/$OUTPUT_REPO.git", branch: main, path: ""}
forgejo: {url: "$base", owner: "$owner"}
EOF
      ;;
  esac
}

# topology_set mono|io|split: writes gitops.topology (io, split) and
# gitops.forgejoTokenSecret (split) in the server's values, or removes them (mono).
topology_set() {
  local f
  case "$1" in
    mono)
      yq -i 'del(.gitops.topology) | del(.gitops.forgejoTokenSecret)' "$SERVER_VALUES"
      ;;
    io|split)
      f="$(mktemp)"
      topology_file "$1" >"$f"
      F="$f" yq -i '.gitops.topology = (load(strenv(F)) | ... style="")
        | (.gitops.topology | key) head_comment = "Written by scripts/configure.sh --topology (io, split): the repositories of\nthe platform, of the projects and of the compiled tree (GITOPS_CONFIG)."' "$SERVER_VALUES"
      rm -f "$f"
      if [[ "$1" == split ]]; then
        S="$FORGEJO_TOKEN_SECRET" yq -i '.gitops.forgejoTokenSecret = strenv(S)' "$SERVER_VALUES"
      else
        yq -i 'del(.gitops.forgejoTokenSecret)' "$SERVER_VALUES"
      fi
      ;;
  esac
  [[ "$(topology_current)" == "$1" ]] || die "could not set the topology $1 in ${SERVER_VALUES#"$ROOT"/}"
}

# ci_topology_file TOPOLOGY: the topology file of the CI, which the workflow of each
# repository of the sources carries (scripts/lib/forgejo.sh, forgejo_ci_workflow), the
# server's without forgejo (the CI creates no repository; okdp-gitops requires the
# token file of a forgejo section, which the CI has not).
ci_topology_file() { topology_file "$1" | grep -v '^forgejo:'; }

# CI_INSECURE_HTTP_HOSTS: the hosts the CI's token may reach over http://, in clear,
# comma separated, globs allowed (okdp-gitops workflow refuses a topology with an
# http:// URL of any other host, okdp-gitops compile sends no credential there): the
# cluster's services, the in-cluster Forgejo of forgejo_cluster_url among them. The
# workflow carries it, as GITOPS_INSECURE_HTTP_HOSTS of the job's environment.
CI_INSECURE_HTTP_HOSTS="${CI_INSECURE_HTTP_HOSTS:-*.svc.cluster.local}"

# ci_http_refused TOPOLOGY: the http:// URLs of the CI's topology whose host
# CI_INSECURE_HTTP_HOSTS does not allow, one per line; none: okdp-gitops workflow
# writes the workflow.
ci_http_refused() {
  local url host pattern ok patterns
  IFS=, read -ra patterns <<<"$CI_INSECURE_HTTP_HOSTS"
  while read -r url; do
    [[ "${url,,}" == http://* ]] || continue
    host="${url#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}"; host="${host,,}"
    ok=false
    for pattern in "${patterns[@]}"; do
      pattern="${pattern// /}"
      # shellcheck disable=SC2053 # the pattern is a glob
      [[ -n "$pattern" && "$host" == ${pattern,,} ]] && ok=true
    done
    $ok || echo "$url"
  done < <(ci_topology_file "$1" | yq -r '.platform.url, .projects.url, .output.url')
}

# The output repository of a topology: compiled/, argocd/ at its root.
output_url() {
  case "$1" in
    mono) mono_url ;;
    *) echo "$(forgejo_cluster_url)/$(forgejo_owner)/$OUTPUT_REPO.git" ;;
  esac
}
output_repo() { local u; u="$(output_url "$1")"; u="${u##*/}"; echo "${u%.git}"; }

# topology_describe TOPOLOGY: its repositories, one line each.
topology_describe() {
  local owner p
  owner="$(forgejo_owner)"
  case "$1" in
    mono)
      echo "  deployments  $owner/$(mono_repo) (platform.yaml, catalogs.yaml, projects/, compiled/, argocd/)"
      ;;
    io)
      echo "  input        $owner/$INPUT_REPO (platform.yaml, catalogs.yaml, projects/)"
      echo "  output       $owner/$OUTPUT_REPO (compiled/, argocd/)"
      ;;
    split)
      echo "  platform     $owner/$PLATFORM_REPO"
      for p in $(project_names); do
        echo "  project      $owner/$PROJECT_REPO_PREFIX$p"
      done
      echo "  output       $owner/$OUTPUT_REPO (compiled/, argocd/)"
      ;;
  esac
}

# ---------------------------------------------------- argocd/ and flux/ entry points

# The repository the entry points read now, from flux/sync.yaml: the URL of
# GitRepository okdp-gitops; and the prefix of its paths, "" (the output at the root of
# its repository: ./compiled/projects).
entry_url() { yq 'select(.kind == "GitRepository") | .spec.url' "$ROOT/flux/sync.yaml"; }
entry_prefix() {
  local p
  p="$(yq 'select(.kind == "Kustomization" and .metadata.name == "okdp") | .spec.path' "$ROOT/flux/sync.yaml")"
  p="${p#./}"; echo "${p%compiled/projects}"
}

sed_re() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/#]/\\&/g'; }
sed_repl() { printf '%s' "$1" | sed -e 's/[\/&#]/\\&/g'; }

# entry_points_retarget URL: points argocd/ and flux/ at the repository URL: line
# edits, so that the files keep their comments and layout. Returns 1 when they already
# do.
entry_points_retarget() {
  local url="$1" old_url f
  old_url="$(entry_url)"
  [[ "$old_url" != "$url" ]] || return 1
  while IFS= read -r f; do
    sed -i -e "s#$(sed_re "$old_url")#$(sed_repl "$url")#g" "$f"
  done < <(find "$ROOT/argocd" "$ROOT/flux" -name '*.yaml' | sort)
  [[ "$(entry_url)" == "$url" ]] || die "could not point argocd/ and flux/ at $url"
}

# ------------------------------------------------------------------- projects

# The projects of the layout: projects/<p>/project.yaml (a project is a directory of
# projects/ with a project.yaml).
project_names() {
  local f
  for f in "$ROOT"/projects/*/project.yaml; do
    if [[ -f "$f" ]]; then basename "$(dirname "$f")"; fi
  done | sort
}

# projects_file_set TOPOLOGY: projects.yaml lists the projects in split (one repository
# each), and does not exist otherwise. Returns 1 when nothing changed.
projects_file_set() {
  local before="" after="" p
  if [[ -f "$PROJECTS_FILE" ]]; then before="$(cat "$PROJECTS_FILE")"; fi
  if [[ "$1" == split ]]; then
    {
      echo "# Projects of the split topology, one repository $PROJECT_REPO_PREFIX<name> each (written"
      echo "# by scripts/configure.sh --topology split; the console adds the projects it creates)."
      if [[ -z "$(project_names)" ]]; then
        echo "projects: []"
      else
        echo "projects:"
        for p in $(project_names); do echo "  - name: $p"; done
      fi
    } >"$PROJECTS_FILE"
  else
    rm -f "$PROJECTS_FILE"
  fi
  if [[ -f "$PROJECTS_FILE" ]]; then after="$(cat "$PROJECTS_FILE")"; fi
  [[ "$after" != "$before" ]]
}

# ------------------------------------------------------------------- catalogs

# The catalogs of catalogs.yaml (repositories): "<name>\t<url>\t<ref>" lines.
catalog_list() {
  [[ -f "$CATALOG_FILE" ]] || return 0
  yq -r '.repositories[]? | [.name, .url, .ref] | @tsv' "$CATALOG_FILE"
}

# Where each catalog is read from, NAME -> SRC: --catalog NAME=SRC of the scripts and
# OKDP_CATALOGS ("NAME=SRC ...", the flags win); SRC a directory (read as it is) or a
# Git URL (read at the catalog's ref). Without either, the Git checkout of the same
# name next to this repository (read at the catalog's ref, whatever is checked out),
# else https://github.com/OKDP/<name>.git (OKDP_CATALOG_BASE_URL).
declare -A CATALOG_SRC=()
catalog_source_add() {
  [[ "$1" == ?*=?* ]] || die "--catalog '$1': NAME=DIR or NAME=URL"
  CATALOG_SRC["${1%%=*}"]="${1#*=}"
}
catalog_sources_init() { # the --catalog values of the command line
  local c
  for c in ${OKDP_CATALOGS:-} "$@"; do catalog_source_add "$c"; done
}

# catalog_origin NAME: "<kind> <src>", kind dir (a directory, read as it is), checkout
# (a checkout next to this repository, read at the ref) or url.
catalog_origin() {
  local name="$1" src="${CATALOG_SRC[$1]:-}" sib="$SANDBOX_TOP/../$1"
  if [[ -n "$src" ]]; then
    if [[ -d "$src" ]]; then echo "dir $(cd "$src" && pwd)"; else echo "url $src"; fi
  elif [[ -d "$sib" && "$(git -C "$sib" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$sib" && pwd -P)" ]]; then
    echo "checkout $(cd "$sib" && pwd)"
  else
    echo "url ${OKDP_CATALOG_BASE_URL:-https://github.com/OKDP}/$name.git"
  fi
}

# catalog_commit DIR REF: the commit of REF (a branch, a tag, origin/<branch>) in DIR.
catalog_commit() {
  local r
  for r in "$2" "origin/$2" "refs/tags/$2"; do
    git -C "$1" rev-parse -q --verify "$r^{commit}" 2>/dev/null && return 0
  done
  return 1
}

# catalogs_resolve: CATALOG_DIRS, NAME -> the directory okdp-gitops reads the catalog
# from (--catalog NAME=DIR): a directory given as is, else the catalog at its ref,
# unpacked or cloned into $WORK/catalogs/NAME.
declare -A CATALOG_DIRS=()
CATALOGS_RESOLVED=false
catalogs_resolve() {
  local name url ref kind src commit dest
  $CATALOGS_RESOLVED && return 0
  CATALOGS_RESOLVED=true
  while IFS=$'\t' read -r name url ref; do
    read -r kind src <<<"$(catalog_origin "$name")"
    dest="$WORK/catalogs/$name"
    case "$kind" in
      dir)
        CATALOG_DIRS[$name]="$src"
        echo "catalog $name: $src (as it is)" >&2
        ;;
      checkout)
        commit="$(catalog_commit "$src" "$ref")" \
          || die "catalog $name: no $ref in $src (fetch it, or --catalog $name=DIR|URL)"
        rm -rf "$dest"; mkdir -p "$dest"
        git -C "$src" archive "$commit" | tar -x -C "$dest"
        CATALOG_DIRS[$name]="$dest"
        echo "catalog $name: $src at $ref (${commit:0:12})" >&2
        ;;
      url)
        rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
        git clone -q --depth 1 --branch "$ref" "$src" "$dest" 2>"$WORK/clone.log" \
          || { cat "$WORK/clone.log" >&2; die "catalog $name: cannot clone $ref of $src (--catalog $name=DIR|URL)"; }
        CATALOG_DIRS[$name]="$dest"
        echo "catalog $name: $src at $ref" >&2
        ;;
    esac
  done < <(catalog_list)
}

# bootstrap_resolve: BOOTSTRAP, the bootstrap/ of the catalog BOOTSTRAP_CATALOG as
# the catalogs are read (catalogs_resolve: at its ref of catalogs.yaml, from --catalog
# NAME=SRC or OKDP_CATALOGS, the checkout next to this repository, else GitHub), so that
# the prerequisites and the packages are of one commit. Needs WORK (work_init).
bootstrap_resolve() {
  [[ -n "${BOOTSTRAP:-}" ]] && return 0
  catalogs_resolve
  local dir="${CATALOG_DIRS[$BOOTSTRAP_CATALOG]:-}"
  [[ -n "$dir" ]] || die "catalogs.yaml names no catalog $BOOTSTRAP_CATALOG, whose bootstrap/ holds the platform's prerequisites"
  [[ -f "$dir/bootstrap/charts.yaml" ]] || die "catalog $BOOTSTRAP_CATALOG ($dir) has no bootstrap/charts.yaml"
  BOOTSTRAP="$dir/bootstrap"
}

# catalog_args: --catalog NAME=DIR for okdp-gitops, one per resolved catalog.
catalog_args() {
  local name
  for name in $(printf '%s\n' "${!CATALOG_DIRS[@]}" | sort); do
    printf '%s\n' --catalog "$name=${CATALOG_DIRS[$name]}"
  done
}

# -------------------------------------------------------------------- compile

# layout_compile OUT [okdp-gitops compile flags...]: compiles the tree of the layout
# (platform.yaml, catalogs.yaml, projects/ of ROOT) into OUT, the output as its
# repository holds it, at its root, whatever the topology (okdp-gitops compile
# --config, OKDP_GITOPS names it): OUT gets the Argo CD entry point argocd/ of ROOT (its
# root.yaml names the repository of the Applications okdp-gitops writes), then the
# compile writes compiled/. OUT may be ROOT, a layout that holds its output (a clone of
# the mono deployments repository): compiled in place. The catalogs are those of
# catalogs_resolve (call it first).
layout_compile() {
  local out="$1" cfg args=()
  shift
  mono_check
  mkdir -p "$out"; out="$(cd "$out" && pwd)"
  if [[ "$out" != "$ROOT" ]]; then
    rm -rf "$out/argocd"
    cp -R "$ROOT/argocd" "$out/"
  fi
  cfg="$WORK/topology.local.yaml"
  cat >"$cfg" <<EOF
# The tree of the layout, compiled into the output directory (okdp-gitops --config).
platform: {url: "$ROOT", path: ""}
projects: {url: "$ROOT", path: "projects/{project}"}
output: {url: "$out", path: ""}
EOF
  mapfile -t args < <(catalog_args)
  "${OKDP_GITOPS:-okdp-gitops}" compile --config "$cfg" "${args[@]}" "$@"
}
