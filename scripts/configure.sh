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
#   --topology io|split         the Forgejo repositories of the parts, the output
#                               always apart (okdp/okdp-output: compiled/,
#                               argocd/, the CI alone writes it): io (a small team)
#                               okdp/okdp-platform (platform.yaml, catalogs.yaml:
#                               the platform admins) and okdp/okdp-projects
#                               (projects/: every writer writes every project);
#                               split (per-project permissions) okdp/okdp-platform
#                               and one okdp/okdp-project-<p> per project. Writes
#                               gitops.topology (and, split,
#                               gitops.forgejoTokenSecret) of the server, removes
#                               an older layout's gitops.repoURL, branch and path,
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
#   when it does not compile) with its CI, the output repository's workflow, the
#   only one (okdp-gitops workflow --for output: a compile of the sources every 2
#   minutes, the topology in it), creates the organization okdp and the repositories
#   of the topology (private), copies the service catalogs of catalogs.yaml (their
#   ref, from --catalog, else the checkouts next to this repository, else GitHub),
#   gives each its own Forgejo account, none an admin, through teams of the
#   repositories it needs only (scripts/lib/forgejo.sh, forgejo_accounts): okdp-ci,
#   the CI, writes the output and reads the sources and the catalogs, its token
#   (write:repository) the Actions secret OKDP_GITOPS_TOKEN of the output repository
#   only; okdp-reader, the engines, reads the output only, its token (read:repository)
#   in Secrets argocd/okdp-gitops-reader and flux-system/okdp-gitops-reader; when the
#   layout installs the control plane, okdp-console writes the sources (split: may
#   create repositories) and reads the output and the catalogs, a token of it
#   (write:repository) in the server's Secret gitops.credentialsSecret and, split,
#   another (write:organization) in gitops.forgejoTokenSecret, in its namespace, no
#   password (an older sandbox's single account okdp-gitops is deleted), turns
#   Actions on in the output repository only, registers the CI runner
#   (forgejo/forgejo-runner) for the output repository only, never a repository of
#   the sources nor the organization (its registration secret in its namespace),
#   protects the output's main (only okdp-ci pushes there), pushes each part, the
#   sources (no workflow, no secret) as the admin then the output as okdp-ci, as one
#   commit on top of the repository's main (refused when the console committed there
#   since the last push; --force replaces the console's changes). The people get
#   their teams from their Keycloak groups: the platform's administrators
#   (global.okdp.access.admins of platform.yaml) the organization's owners, the
#   groups of each project's roles (its compiled AppProject, project.yaml access, by
#   default okdp-project-<p> editor) a team okdp-project-<p> writing its repository
#   (split okdp-project-<p>, io okdp-projects), okdp-project-<p>-viewers reading it,
#   never the platform's repository nor the output; the OAuth source keycloak of
#   Forgejo maps the groups to the teams, created by --sign-in (once the platform is
#   up, README after step 5), updated by every --push once it exists. It signs in to
#   Forgejo as its admin, of the Secret gitea.admin.existingSecret of sandbox-charts'
#   bootstrap/forgejo (README, step 3).
#   --dry-run compiles, prints what it would push and keeps the parts (in --work DIR,
#   or a printed directory).
#
# Usage: configure.sh [-i|--interactive] [--engine argocd|flux]
#                     [--topology io|split] [--root DIR]
#        configure.sh --push [--force] [--sign-in] [--dry-run] [--work DIR]
#                     [--catalog NAME=SRC]...
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
SIGN_IN=false
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
    --sign-in) SIGN_IN=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --work) WORK_DIR="$2"; shift 2 ;;
    --catalog) CATALOGS+=("$2"); shift 2 ;;
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '18,87p' "$0"; exit 0 ;;
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
  topology_require
  echo "engine:   $CUR_ENGINE"
  echo "topology: $CUR_TOPOLOGY"
  topology_describe "$CUR_TOPOLOGY"
  echo "Argo CD and Flux read $(entry_url)"
  exit 0
fi

# ---------------------------------------------------------------------- push

# The files of the tree, the platform's part: okdp-compiler's and okdp-gitops'.
PLATFORM_PATHS=(platform.yaml catalogs.yaml projects.yaml)

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
  local owner prefix sha message p force=() out output split sources=()
  # shellcheck source=lib/forgejo.sh
  source "$SCRIPTS/lib/forgejo.sh"
  TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || die "--push sends the committed layout: $ROOT is not in a Git repository"
  [[ -z "$(git -C "$ROOT" status --porcelain -- .)" ]] \
    || die "uncommitted changes in $ROOT: commit them first (--push sends HEAD)"
  command -v "${OKDP_GITOPS:-okdp-gitops}" >/dev/null \
    || die "okdp-gitops is required to compile the layout (https://github.com/OKDP/okdp-gitops: make build; or set OKDP_GITOPS)"
  topology_require
  prefix="$(git -C "$ROOT" rev-parse --show-prefix)"; prefix="${prefix%/}"
  sha="$(git -C "$TOP" rev-parse --short HEAD)"
  message="okdp-sandbox $sha: $(git -C "$TOP" log -1 --format=%s)"
  owner="$(forgejo_owner)"
  if $FORCE; then force=(--force); fi

  if $DRY_RUN && [[ -z "$WORK_DIR" ]]; then WORK_DIR="$(mktemp -d)"; fi
  work_init "$WORK_DIR"
  catalog_sources_init "${CATALOGS[@]}"

  # The committed layout, compiled into the tree of the output repository, and its
  # CI, the only workflow, the topology in it: refused (nothing pushed) as the compile.
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
  ci_topology_file "$CUR_TOPOLOGY" >"$WORK/topology.ci.yaml"
  forgejo_output_workflow "$out" "$WORK/topology.ci.yaml" \
    || die "okdp-gitops workflow refuses the CI's topology ($CUR_TOPOLOGY): nothing pushed"

  echo "Pushing $sha, $CUR_TOPOLOGY topology, to Forgejo"
  forgejo_init
  forgejo_connect
  forgejo_ensure_org "$owner"
  forgejo_push_catalogs

  # The parts of the sources, no workflow among them, and their repositories, then
  # the output's, created before anything is pushed: the CI's token and runner are in
  # place when its schedule first runs.
  part "$WORK/parts/$PLATFORM_REPO" "$prefix" "${PLATFORM_PATHS[@]}"
  forgejo_ensure_repo "$owner" "$PLATFORM_REPO" "OKDP platform sources, the platform admins': platform.yaml, catalogs.yaml ($CUR_TOPOLOGY topology)"
  sources+=("$PLATFORM_REPO")
  case "$CUR_TOPOLOGY" in
    io)
      part "$WORK/parts/$PROJECTS_REPO" "$prefix" projects
      forgejo_ensure_repo "$owner" "$PROJECTS_REPO" "OKDP projects, projects/<p>/, every writer trusted with every project (io topology)"
      sources+=("$PROJECTS_REPO")
      ;;
    split)
      for p in $(yq '.projects[].name' "$PROJECTS_FILE"); do
        [[ -d "$ROOT/projects/$p" ]] || die "projects.yaml lists $p, projects/$p does not exist"
        part "$WORK/parts/$PROJECT_REPO_PREFIX$p" "${prefix:+$prefix/}projects/$p"
        forgejo_ensure_repo "$owner" "$PROJECT_REPO_PREFIX$p" "OKDP project $p, its team's (split topology)"
        sources+=("$PROJECT_REPO_PREFIX$p")
      done
      ;;
  esac
  output="$(output_repo "$CUR_TOPOLOGY")"
  forgejo_ensure_repo "$owner" "$output" "OKDP compiled tree, read by Argo CD and Flux, written by its CI alone ($CUR_TOPOLOGY topology)"
  # Actions: the output's only; no workflow of the sources runs.
  for p in "${sources[@]}"; do forgejo_set_actions "$owner" "$p" false; done
  forgejo_set_actions "$owner" "$output" true
  # The accounts, none an admin: okdp-ci (writes the output, reads the sources and
  # the catalogs), okdp-reader (reads the output), okdp-console (writes the sources,
  # reads the output and the catalogs) when the layout installs the control plane.
  split="$([[ "$CUR_TOPOLOGY" == split ]] && echo true || echo false)"
  forgejo_accounts "$owner" "$split" "$output" "${sources[@]}"
  # The people's teams, from the compiled tree: the groups of the platform's admins
  # and of each project's roles.
  forgejo_people_teams "$owner" "$CUR_TOPOLOGY" "$out"
  # The CI: its token in the output repository only, its runner registered for it
  # only, its main pushed by okdp-ci alone (no force push, no deletion).
  forgejo_ci_token "$owner" "$output" "${sources[@]}"
  forgejo_register_runner "$owner" "$output"
  forgejo_protect_branch "$owner" "$output" main
  # The engines' read token of the output repository, in argocd (Argo CD's
  # repository credentials) and flux-system (Flux's GitRepository secretRef): one
  # token of okdp-reader, two Secrets.
  forgejo_engine_secrets argocd okdp-gitops-reader flux-system okdp-gitops-reader
  if ! $DRY_RUN; then
    # Argo CD discovers repository credentials from labeled Secrets: a repository
    # (not a repo-creds template, which would match every repository under its URL
    # prefix), the output repository's exact URL.
    kubectl -n argocd label secret okdp-gitops-reader argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
    kubectl -n argocd patch secret okdp-gitops-reader --type merge \
      -p "$(jq -cn --arg u "$(output_url "$CUR_TOPOLOGY")" '{stringData: {url: $u, type: "git"}}')" >/dev/null
  fi

  # The sources, as the admin, then the output, as okdp-ci: the CI compiles them at
  # its next run.
  for p in "${sources[@]}"; do
    forgejo_push_tree "$WORK/parts/$p" "$owner" "$p" "$message" "${force[@]}"
  done
  forgejo_push_tree "$out" "$owner" "$output" "$message" "${force[@]}" --as-ci
  # The console's tokens (split: also the one that creates the projects'
  # repositories), in the server's namespace.
  forgejo_console_secrets "$split"
  # The sign-in with Keycloak, its group-team map: created with --sign-in, else
  # updated when it exists.
  forgejo_sign_in "$owner" "$SIGN_IN"
  if $DRY_RUN; then
    echo "Dry run: nothing pushed; the parts are in $WORK/parts"
    return
  fi
  cat <<EOF

Next: install $([[ "$CUR_ENGINE" == argocd ]] && echo "Argo CD (README, step 5a)" || echo "Flux (README, step 5b)");
it reads $(entry_url).
EOF
}

if $SIGN_IN && ! $PUSH; then die "--sign-in goes with --push"; fi
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
    echo "Repositories, the output always apart: io (a small team), a platform and a" >&2
    echo "projects repository; split (per-project permissions), a platform repository" >&2
    echo "and one per project." >&2
    TOPOLOGY="$(ask "Topology:" "$(one_of "$CUR_TOPOLOGY" "${TOPOLOGIES[@]}" && echo "$CUR_TOPOLOGY" || echo io)" "${TOPOLOGIES[@]}")"
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

# Also the same topology with other repositories (an older layout's, a hand edit),
# or the single repository of the removed mono topology still named.
if [[ "$TOPOLOGY" != "$CUR_TOPOLOGY" ]] || ! topology_matches "$TOPOLOGY" \
  || [[ "$(yq '.gitops | has("repoURL") or has("branch") or has("path")' "$SERVER_VALUES")" == true ]]; then
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
