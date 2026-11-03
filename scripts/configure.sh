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

# Configures the sandbox (gitops/README.md, "Topologies"), in two steps.
#
# 1. Choose, in the layout only (nothing is applied; commit the result):
#   --engine argocd|flux        gitops.engine of the control plane server (the
#                               console writes for that engine);
#   --topology mono|io|split    the Forgejo repositories of the parts: mono one
#                               deployments repository (okdp/okdp-deployments:
#                               the tree, compiled/, argocd/); io okdp/okdp-input
#                               (platform.yaml, catalogs.yaml, projects/) and
#                               okdp/okdp-output (compiled/, argocd/); split
#                               okdp/okdp-platform, one okdp/okdp-project-<p> per
#                               project and okdp/okdp-output. Writes gitops.topology
#                               (and, split, gitops.forgejoTokenSecret) of the server,
#                               points argocd/ and flux/ at the output repository,
#                               writes (split) or removes projects.yaml.
#   Without a choice on a terminal, or with -i, asks for both (the current values are
#   the defaults). Choose before the first install: switching engines or topologies
#   means reinstalling.
#
# 2. --push: puts the committed layout (HEAD) on the sandbox's Forgejo (installed with
#   the platform's dependencies, README step 3; current kubectl context, port-forward,
#   or FORGEJO_URL):
#   compiles it into the output tree (as scripts/compile.sh does; nothing is pushed
#   when it does not compile), creates the organization okdp and the repositories of
#   the topology (public), copies the service catalogs of catalogs.yaml (their
#   ref, from --catalog, else the checkouts next to this repository, else GitHub),
#   gives the console and the CI their own Forgejo account, okdp-gitops, not an
#   admin, with write access to the repositories of the topology only (its password
#   in the console's Secret, in its namespace; a token of it in the Actions secret
#   OKDP_GITOPS_TOKEN of each repository of the sources, the CI's), registers the CI
#   runner (forgejo/forgejo-runner) for each repository of the sources, never the
#   organization (its registration secrets in its namespace), puts the CI in them
#   (the workflow, the topology in it), pushes each part, the sources then the
#   output, as one commit on top of the repository's main (refused when the console
#   committed there since the last push; --force replaces the console's changes),
#   and, split, creates an access token of that account for the server, in the
#   Secret gitops.forgejoTokenSecret of its namespace. It signs in to Forgejo as its
#   admin, of the Secret gitea.admin.existingSecret of sandbox-charts'
#   bootstrap/forgejo (README, step 3).
#   --dry-run compiles, prints what it would push and keeps the parts (in --work DIR,
#   or a printed directory).
#
# Usage: configure.sh [-i|--interactive] [--engine argocd|flux]
#                     [--topology mono|io|split] [--root DIR]
#        configure.sh --push [--force] [--dry-run] [--work DIR] [--catalog NAME=SRC]...
#        configure.sh --show
# --catalog NAME=SRC: see scripts/compile.sh. Requires bash >= 4, yq v4; --push also
# git, okdp-gitops (https://github.com/OKDP/okdp-gitops: make build; OKDP_GITOPS names
# it, OKDP_GITOPS_ARGS adds arguments), curl, jq and kubectl.

set -euo pipefail
export LC_ALL=C

PROG=configure
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
ENGINE=""
TOPOLOGY=""
INTERACTIVE=false
SHOW=false
PUSH=false
FORCE=false
DRY_RUN=false
WORK_DIR=""
CATALOGS=()

ENGINES=(argocd flux)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --topology) TOPOLOGY="$2"; shift 2 ;;
    -i|--interactive) INTERACTIVE=true; shift ;;
    --show) SHOW=true; shift ;;
    --push) PUSH=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --work) WORK_DIR="$2"; shift 2 ;;
    --catalog) CATALOGS+=("$2"); shift 2 ;;
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '18,66p' "$0"; exit 0 ;;
    *) echo "configure: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null || { echo "configure: yq v4 is required" >&2; exit 2; }
yq --version 2>&1 | grep -q 'version v4' || { echo "configure: yq v4 (mikefarah) is required" >&2; exit 2; }

# shellcheck source=lib/topology.sh
source "$SCRIPTS/lib/topology.sh"

CUR_ENGINE="$(yq '.gitops.engine // ""' "$SERVER_VALUES")"
CUR_TOPOLOGY="$(topology_current)"
one_of "$CUR_ENGINE" "${ENGINES[@]}" \
  || die "unexpected gitops.engine '$CUR_ENGINE' in ${SERVER_VALUES#"$ROOT"/}"

if $SHOW; then
  echo "engine:   $CUR_ENGINE"
  echo "topology: $CUR_TOPOLOGY"
  topology_describe "$CUR_TOPOLOGY"
  echo "Argo CD and Flux read $(entry_url)"
  exit 0
fi

# ---------------------------------------------------------------------- push

# The files of the tree, the platform's part: okdp-compiler's and okdp-gitops'.
PLATFORM_PATHS=(platform.yaml catalogs.yaml projects.yaml)
# The whole tree (one repository: mono, io).
TREE_PATHS=(platform.yaml catalogs.yaml projects.yaml projects)

# part DEST TREE [PATHS...]: the committed files (HEAD) of TREE, a directory of this
# repository ("" for its root), or only its PATHS that exist, into DEST.
part() {
  local dest="$1" tree="$2" p paths=(); shift 2
  for p in "$@"; do
    if git -C "$TOP" cat-file -e "HEAD:${tree:+$tree/}$p" 2>/dev/null; then paths+=("$p"); fi
  done
  rm -rf "$dest"; mkdir -p "$dest"
  if [[ $# -eq 0 || ${#paths[@]} -gt 0 ]]; then
    git -C "$TOP" archive "HEAD:$tree" "${paths[@]}" | tar -x -C "$dest"
  fi
}

push() {
  local owner prefix sha message p force=() out repos=() sources=()
  # shellcheck source=lib/forgejo.sh
  source "$SCRIPTS/lib/forgejo.sh"
  TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || die "--push sends the committed layout: $ROOT is not in a Git repository"
  [[ -z "$(git -C "$ROOT" status --porcelain -- .)" ]] \
    || die "uncommitted changes in $ROOT: commit them first (--push sends HEAD)"
  command -v "${OKDP_GITOPS:-okdp-gitops}" >/dev/null \
    || die "okdp-gitops is required to compile the layout (https://github.com/OKDP/okdp-gitops: make build; or set OKDP_GITOPS)"
  mono_check
  prefix="$(git -C "$ROOT" rev-parse --show-prefix)"; prefix="${prefix%/}"
  sha="$(git -C "$TOP" rev-parse --short HEAD)"
  message="okdp-sandbox $sha: $(git -C "$TOP" log -1 --format=%s)"
  owner="$(forgejo_owner)"
  if $FORCE; then force=(--force); fi

  if $DRY_RUN && [[ -z "$WORK_DIR" ]]; then WORK_DIR="$(mktemp -d)"; fi
  work_init "$WORK_DIR"
  catalog_sources_init "${CATALOGS[@]}"

  # The committed layout, compiled into the tree of the output repository.
  echo "Compiling $sha ($CUR_TOPOLOGY topology)"
  part "$WORK/layout" "$prefix"
  catalogs_resolve
  out="$WORK/parts/$(output_repo "$CUR_TOPOLOGY")"
  rm -rf "$out"
  # Word splitting of OKDP_GITOPS_ARGS is intended.
  # shellcheck disable=SC2086
  (ROOT="$WORK/layout"; layout_compile "$out" ${OKDP_GITOPS_ARGS:-}) >"$WORK/compile.log" 2>&1 \
    || { cat "$WORK/compile.log" >&2; die "the layout does not compile: nothing pushed"; }
  echo "compiled: $(find "$out/compiled" -type f | wc -l) files in compiled/"

  echo "Pushing $sha, $CUR_TOPOLOGY topology, to Forgejo"
  forgejo_init
  forgejo_connect
  forgejo_ensure_org "$owner"
  forgejo_push_catalogs

  # The parts of the sources, their CI (the workflow carries the topology), and their
  # repositories, created before anything is pushed: the CI's token and runner are
  # in place when the first push starts a run.
  ci_topology_file "$CUR_TOPOLOGY" >"$WORK/topology.ci.yaml"
  case "$CUR_TOPOLOGY" in
    mono)
      # One repository: the tree next to the output.
      for p in "${TREE_PATHS[@]}"; do
        if [[ -e "$WORK/layout/$p" ]]; then cp -R "$WORK/layout/$p" "$out/"; fi
      done
      forgejo_ci_workflow "$out" "$WORK/topology.ci.yaml"
      forgejo_ensure_repo "$owner" "$(mono_repo)" "OKDP deployments repository: the sources and the compiled tree (mono topology)"
      sources+=("$(mono_repo)")
      ;;
    io)
      part "$WORK/parts/$INPUT_REPO" "$prefix" "${TREE_PATHS[@]}"
      forgejo_ci_workflow "$WORK/parts/$INPUT_REPO" "$WORK/topology.ci.yaml"
      forgejo_ensure_repo "$owner" "$INPUT_REPO" "OKDP sources: platform.yaml, catalogs.yaml, projects/ (io topology)"
      sources+=("$INPUT_REPO")
      ;;
    split)
      part "$WORK/parts/$PLATFORM_REPO" "$prefix" "${PLATFORM_PATHS[@]}"
      forgejo_ci_workflow "$WORK/parts/$PLATFORM_REPO" "$WORK/topology.ci.yaml"
      forgejo_ensure_repo "$owner" "$PLATFORM_REPO" "OKDP platform sources (split topology)"
      sources+=("$PLATFORM_REPO")
      for p in $(yq '.projects[].name' "$PROJECTS_FILE"); do
        [[ -d "$ROOT/projects/$p" ]] || die "projects.yaml lists $p, projects/$p does not exist"
        part "$WORK/parts/$PROJECT_REPO_PREFIX$p" "${prefix:+$prefix/}projects/$p"
        forgejo_ci_workflow "$WORK/parts/$PROJECT_REPO_PREFIX$p" "$WORK/topology.ci.yaml"
        forgejo_ensure_repo "$owner" "$PROJECT_REPO_PREFIX$p" "OKDP project $p (split topology)"
        sources+=("$PROJECT_REPO_PREFIX$p")
      done
      ;;
  esac
  for p in "${sources[@]}"; do forgejo_enable_actions "$owner" "$p"; done
  if [[ "$CUR_TOPOLOGY" != mono ]]; then
    forgejo_ensure_repo "$owner" "$OUTPUT_REPO" "OKDP compiled tree, read by Argo CD and Flux ($CUR_TOPOLOGY topology)"
    forgejo_enable_actions "$owner" "$OUTPUT_REPO"
    repos=("${sources[@]}" "$OUTPUT_REPO")
  else
    repos=("${sources[@]}")
  fi
  forgejo_bot "$owner" "$([[ "$CUR_TOPOLOGY" == split ]] && echo true || echo false)" "${repos[@]}"
  if [[ "$CUR_TOPOLOGY" != mono ]]; then
    # The write token in the output repository only; each source repository
    # gets a dispatch token to trigger the output's workflow on stale compiles.
    forgejo_ci_token "$owner" "$OUTPUT_REPO" "${sources[@]}"
    forgejo_register_runner "$owner" "${sources[@]}" "$OUTPUT_REPO"
  else
    # Mono: the source is the output; the write token goes there.
    forgejo_ci_token "$owner" "${sources[0]}" "${sources[@]}"
    forgejo_register_runner "$owner" "${sources[@]}"
  fi

  # Branch protection on the output repository's main: no force push, no deletion.
  forgejo_protect_branch "$owner" "$(output_repo "$CUR_TOPOLOGY")" main
  # The engines' read token for private repositories, in argocd (Argo CD's
  # repository credentials) and flux-system (Flux's GitRepository secretRef): one
  # token, two Secrets.
  forgejo_engine_secrets "$owner" argocd okdp-gitops-reader flux-system okdp-gitops-reader
  if ! $DRY_RUN; then
    # Argo CD discovers repository credentials from labeled Secrets (repo-creds: a
    # credential template matching all repositories under the Forgejo URL).
    kubectl -n argocd label secret okdp-gitops-reader argocd.argoproj.io/secret-type=repo-creds --overwrite >/dev/null 2>&1 || true
    kubectl -n argocd patch secret okdp-gitops-reader --type merge \
      -p "$(jq -cn --arg u "$(forgejo_cluster_url)" '{stringData: {url: $u, type: "git"}}')" >/dev/null
  fi

  # The output repository's own workflow (split/io): triggered by dispatch from the
  # source repositories' check workflows, it compiles and pushes with the write token.
  if [[ "$CUR_TOPOLOGY" != mono ]]; then
    forgejo_output_workflow "$out" "$WORK/topology.ci.yaml"
  fi

  # The sources, then the output.
  if [[ "$CUR_TOPOLOGY" != mono ]]; then
    for p in "${sources[@]}"; do
      forgejo_push_tree "$WORK/parts/$p" "$owner" "$p" "$message" "${force[@]}"
    done
  fi
  forgejo_push_tree "$out" "$owner" "$(output_repo "$CUR_TOPOLOGY")" "$message" "${force[@]}"
  if [[ "$CUR_TOPOLOGY" == split ]]; then
    forgejo_token_secret "$SERVER_NAMESPACE" \
      "$(yq '.gitops.forgejoTokenSecret // ""' "$SERVER_VALUES")"
  fi
  if $DRY_RUN; then
    echo "Dry run: nothing pushed; the parts are in $WORK/parts"
    return
  fi
  cat <<EOF

Next: install $([[ "$CUR_ENGINE" == argocd ]] && echo "Argo CD (README, step 5a)" || echo "Flux (README, step 5b)");
it reads $(entry_url).
EOF
}

if $PUSH; then
  if [[ -n "$ENGINE$TOPOLOGY" ]] || $INTERACTIVE; then
    die "--push sends the committed layout: configure, commit, then push (two runs)"
  fi
  push
  exit 0
fi

# ----------------------------------------------------------------- configure

# Numbered menu on stderr; prints the choice. Enter keeps the default.
ask() { # prompt default choices...
  local prompt="$1" def="$2"; shift 2
  local i reply
  echo "$prompt" >&2
  i=1
  for c in "$@"; do
    printf '  %d) %s%s\n' "$i" "$c" "$([[ "$c" == "$def" ]] && echo ' (current)')" >&2
    i=$((i + 1))
  done
  while true; do
    read -r -p "Choice [$def]: " reply </dev/tty >&2 || exit 1
    [[ -z "$reply" ]] && { echo "$def"; return; }
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= $# )); then
      echo "${!reply}"; return
    fi
    one_of "$reply" "$@" && { echo "$reply"; return; }
    echo "  answer 1-$#, a name, or Enter" >&2
  done
}

if [[ -z "$ENGINE" && -z "$TOPOLOGY" && -t 0 ]]; then
  INTERACTIVE=true
fi
if $INTERACTIVE; then
  [[ -r /dev/tty ]] || { echo "configure: --interactive needs a terminal" >&2; exit 2; }
  [[ -n "$ENGINE" ]] || ENGINE="$(ask "GitOps engine:" "$CUR_ENGINE" "${ENGINES[@]}")"
  if [[ -z "$TOPOLOGY" ]]; then
    echo "Repositories: mono, one deployments repository; io, an input and an output" >&2
    echo "repository; split, a platform repository, one per project and an output one." >&2
    TOPOLOGY="$(ask "Topology:" "$CUR_TOPOLOGY" "${TOPOLOGIES[@]}")"
  fi
  echo >&2
  echo "engine:   $CUR_ENGINE -> $ENGINE" >&2
  echo "topology: $CUR_TOPOLOGY -> $TOPOLOGY" >&2
  if [[ "$ENGINE" == "$CUR_ENGINE" && "$TOPOLOGY" == "$CUR_TOPOLOGY" ]]; then
    echo "Nothing to change." >&2
    exit 0
  fi
  read -r -p "Apply? [Y/n] " reply </dev/tty >&2 || exit 1
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]] || { echo "Aborted." >&2; exit 1; }
fi

if [[ -z "$ENGINE" && -z "$TOPOLOGY" ]]; then
  echo "configure: nothing to do (--engine, --topology, -i, --push or --show; --help)" >&2
  exit 2
fi
ENGINE="${ENGINE:-$CUR_ENGINE}"
TOPOLOGY="${TOPOLOGY:-$CUR_TOPOLOGY}"
one_of "$ENGINE" "${ENGINES[@]}" || { echo "configure: --engine: one of ${ENGINES[*]}" >&2; exit 2; }
one_of "$TOPOLOGY" "${TOPOLOGIES[@]}" || { echo "configure: --topology: one of ${TOPOLOGIES[*]}" >&2; exit 2; }

changed=false

if [[ "$ENGINE" != "$CUR_ENGINE" ]]; then
  # Line edit, so that the file keeps its comments and layout byte for byte.
  sed -i -E "s/^(  engine: )$CUR_ENGINE\$/\1$ENGINE/" "$SERVER_VALUES"
  [[ "$(yq '.gitops.engine' "$SERVER_VALUES")" == "$ENGINE" ]] \
    || die "could not set gitops.engine in ${SERVER_VALUES#"$ROOT"/}"
  echo "engine: $CUR_ENGINE -> $ENGINE (${SERVER_VALUES#"$ROOT"/})"
  changed=true
fi

if [[ "$TOPOLOGY" != "$CUR_TOPOLOGY" ]]; then
  topology_set "$TOPOLOGY"
  echo "topology: $CUR_TOPOLOGY -> $TOPOLOGY (${SERVER_VALUES#"$ROOT"/})"
  changed=true
fi
# The entry points and projects.yaml follow the topology (also after a hand edit of
# the server's values); the CI's topology is its workflow's, written at the push.
if entry_points_retarget "$(output_url "$TOPOLOGY")"; then
  echo "  argocd/, flux/ -> $(entry_url)"
  changed=true
fi
if projects_file_set "$TOPOLOGY"; then
  if [[ -f "$PROJECTS_FILE" ]]; then
    echo "  ${PROJECTS_FILE#"$ROOT"/}: $(project_names | tr '\n' ' ')"
  else
    echo "  ${PROJECTS_FILE#"$ROOT"/}: removed"
  fi
  changed=true
fi

if $changed; then
  cat <<EOF

Next: review and commit, then put it on Forgejo with scripts/configure.sh --push, which
compiles it (README, step 4); then install $([[ "$ENGINE" == argocd ]] && echo "Argo CD (README, step 5a)." || echo "Flux (README, step 5b).")
EOF
else
  echo "Already engine=$ENGINE topology=$TOPOLOGY; nothing changed."
fi
