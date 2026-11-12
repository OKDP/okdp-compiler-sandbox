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

# Sourced by the scripts in scripts/, after lib/topology.sh: the sandbox's Forgejo, a
# dependency of the platform installed at the bootstrap (sandbox-charts'
# bootstrap/forgejo, release forgejo of the namespace forgejo), reached through a
# kubectl port-forward of the current context (KUBECONFIG), or at FORGEJO_URL when set
# (e.g. http://localhost:3000), with its admin account, of the Secret
# gitea.admin.existingSecret of its values (README, step 3). Its API creates the
# organization, the repositories (private) and the accounts of the topology, none an
# admin, each reaching its repositories through teams of the organization only
# (forgejo_accounts):
#   okdp-ci       the CI: writes the output repository, the only account its main
#                 takes a push of (forgejo_protect_branch), reads the sources and the
#                 catalogs; its token, write:repository, the output repository's
#                 Actions secret OKDP_GITOPS_TOKEN (forgejo_ci_token), nowhere else;
#   okdp-reader   the engines (Argo CD, Flux): reads the output repository only; its
#                 token, read:repository, in their Secrets (forgejo_engine_secrets);
#   okdp-console  the control plane, only when the layout installs it (the instance
#                 okdp-control-plane-server): writes the sources (split: may create
#                 the repositories of new projects), reads the output and the
#                 catalogs, never writes the output; its tokens in the server's
#                 Secrets (forgejo_console_secrets), never a password.
# People push the sources with their own accounts, signed in through Keycloak, their
# teams from their groups (forgejo_people_teams, forgejo_sign_in).
# Nobody keeps the accounts' passwords: each run sets a new random one, which creates
# their tokens (the account's previous ones deleted), then is forgotten. The CI is
# the output repository's alone: its workflow (forgejo_output_workflow: a compile of
# the sources on a schedule), its Actions, its runner (forgejo_register_runner) and
# its token, the only one; the repositories of the sources hold no workflow, no
# secret and no runner, their Actions off. Git pushes the sources with the admin
# account and the output with okdp-ci's token, through GIT_ASKPASS (never in a URL or
# on a command line); the API gets the credentials in a curl config file and the
# bodies on curl's standard input. With DRY_RUN=true, nothing is called: each action
# is printed, the parts are still built in $WORK.
#
# Requires curl, jq, kubectl (port-forward, the Secrets, the runner's registration),
# git.

# The values Forgejo was installed with (default: sandbox-charts'
# bootstrap/forgejo/values.yaml of the catalog BOOTSTRAP_CATALOG, bootstrap_resolve),
# and its namespace (README, step 3).
FORGEJO_VALUES="${FORGEJO_VALUES:-}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
DRY_RUN="${DRY_RUN:-false}"
# The accounts of the topology (forgejo_accounts), each with teams of its name.
FORGEJO_CI=okdp-ci
FORGEJO_READER=okdp-reader
FORGEJO_CONSOLE=okdp-console
# The single account of an older sandbox, the console's, the CI's and the engines'
# at once, and its teams: deleted (forgejo_legacy_cleanup); the console's Secret of
# its password, before gitops.credentialsSecret was renamed.
FORGEJO_LEGACY_BOT=okdp-gitops
FORGEJO_LEGACY_TEAMS=(okdp-gitops okdp-gitops-read)
FORGEJO_LEGACY_CONSOLE_SECRET=okdp-gitops-bot
# The catalogs of the organization copied to Forgejo (forgejo_push_catalogs), which
# the CI and the console read (forgejo_accounts): the CI's compile and the console
# fetch them with their credentials, the repositories being private.
FORGEJO_CATALOG_REPOS=()

dry() { echo "[dry-run] $*"; }

# secret_write NAMESPACE SECRET KEY=VALUE...: the Secret, with these keys, created or
# updated in the current context (the namespace created if missing). The values reach
# kubectl on its standard input, never on a command line.
secret_write() {
  local namespace="$1" name="$2" kv; shift 2
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$namespace"
    printf '  labels:\n    app.kubernetes.io/managed-by: okdp-sandbox-configure\ntype: Opaque\nstringData:\n'
    for kv in "$@"; do printf '  %s: %s\n' "${kv%%=*}" "$(jq -cn --arg v "${kv#*=}" '$v')"; done
  } | kubectl apply -f - >/dev/null
}

# forgejo_init: the Service of Forgejo and the Secret of its admin account.
forgejo_init() {
  if [[ -z "$FORGEJO_VALUES" ]]; then
    bootstrap_resolve
    FORGEJO_VALUES="$BOOTSTRAP/forgejo/values.yaml"
  fi
  FORGEJO_ADMIN_SECRET="$(yq '.gitea.admin.existingSecret' "$FORGEJO_VALUES")"
  FORGEJO_DEPLOYMENT="$(yq '.fullnameOverride // "forgejo"' "$FORGEJO_VALUES")"
  FORGEJO_SERVICE="$FORGEJO_DEPLOYMENT-http"
  FORGEJO_BODY="$WORK/forgejo.response"
  FORGEJO_ASKPASS="$WORK/askpass.sh"
  cat >"$FORGEJO_ASKPASS" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$OKDP_FORGEJO_USER" ;;
  *) printf '%s\n' "$OKDP_FORGEJO_PASSWORD" ;;
esac
ASKPASS
  chmod 700 "$FORGEJO_ASKPASS"
}

# forgejo_connect: FORGEJO, the URL of Forgejo from here: FORGEJO_URL, or a
# port-forward of its Service (stopped at exit); then its admin account
# (forgejo_admin_login).
forgejo_connect() {
  local port=""
  if [[ -n "${FORGEJO_URL:-}" ]]; then
    FORGEJO="${FORGEJO_URL%/}"
  elif $DRY_RUN; then
    FORGEJO="http://127.0.0.1:<port>"
    dry "kubectl -n $FORGEJO_NAMESPACE port-forward svc/$FORGEJO_SERVICE 0:3000 (context $(kubectl config current-context 2>/dev/null || echo '?'))"
    dry "sign in as the admin of Secret $FORGEJO_NAMESPACE/$FORGEJO_ADMIN_SECRET"
    FORGEJO_USER="<admin>"; FORGEJO_PASSWORD=""
    return
  else
    echo "Forgejo: port-forward of $FORGEJO_NAMESPACE/svc/$FORGEJO_SERVICE (context $(kubectl config current-context))"
    kubectl -n "$FORGEJO_NAMESPACE" port-forward "svc/$FORGEJO_SERVICE" 0:3000 >"$WORK/port-forward.log" 2>&1 &
    FORGEJO_PF=$!
    # shellcheck disable=SC2016 # expanded at exit
    on_exit 'kill "$FORGEJO_PF" 2>/dev/null || true'
    for _ in $(seq 30); do
      port="$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$WORK/port-forward.log" | head -n 1)"
      [[ -n "$port" ]] && break
      kill -0 "$FORGEJO_PF" 2>/dev/null || break
      sleep 1
    done
    [[ -n "$port" ]] || { cat "$WORK/port-forward.log" >&2; die "cannot port-forward to Forgejo (is it installed? README, step 3)"; }
    FORGEJO="http://127.0.0.1:$port"
  fi
  local ready=false
  for _ in $(seq 30); do
    if curl -sf -o /dev/null "$FORGEJO/api/v1/version"; then ready=true; break; fi
    sleep 2
  done
  $ready || die "Forgejo does not answer at $FORGEJO"
  forgejo_admin_login
}

# forgejo_admin_login: FORGEJO_USER and FORGEJO_PASSWORD, the admin account of
# Forgejo, keys username and password of its Secret FORGEJO_ADMIN_SECRET (the
# chart's gitea.admin.existingSecret, created before Forgejo: README, step 3). A
# sandbox installed before that Secret has the chart's own Secret <deployment>-admin
# instead, whose password was committed: the admin then gets a new random password,
# written to FORGEJO_ADMIN_SECRET, which the chart keeps once the layout pushed uses it
# (passwordMode keepUpdated).
forgejo_admin_login() {
  local legacy="$FORGEJO_DEPLOYMENT-admin" user password=""
  if FORGEJO_USER="$(secret_value "$FORGEJO_NAMESPACE" "$FORGEJO_ADMIN_SECRET" username)" \
    && FORGEJO_PASSWORD="$(secret_value "$FORGEJO_NAMESPACE" "$FORGEJO_ADMIN_SECRET" password)" \
    && [[ -n "$FORGEJO_USER" && -n "$FORGEJO_PASSWORD" ]]; then
    forgejo_api GET /user
    [[ "$FORGEJO_STATUS" != 200 ]] || return 0
    # Set on the admin below, when Forgejo still has the committed password.
    password="$FORGEJO_PASSWORD"
  fi
  if user="$(secret_value "$FORGEJO_NAMESPACE" "$legacy" username)" \
    && FORGEJO_PASSWORD="$(secret_value "$FORGEJO_NAMESPACE" "$legacy" password)" \
    && [[ -n "$user" ]]; then
    FORGEJO_USER="$user"
    forgejo_api GET /user
    if [[ "$FORGEJO_STATUS" == 200 ]]; then
      [[ -n "$password" ]] || password="$(random_hex 24)"
      forgejo_api PATCH "/admin/users/$user" "$(jq -cn --arg u "$user" --arg p "$password" \
        '{login_name: $u, source_id: 0, password: $p, must_change_password: false}')"
      [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot change the password of the Forgejo admin $user"
      secret_write "$FORGEJO_NAMESPACE" "$FORGEJO_ADMIN_SECRET" "username=$user" "password=$password"
      FORGEJO_PASSWORD="$password"
      echo "Forgejo admin $user: a new password, in Secret $FORGEJO_NAMESPACE/$FORGEJO_ADMIN_SECRET (the one of $legacy was committed)"
      return 0
    fi
  fi
  die "cannot sign in to Forgejo as its admin: Secret $FORGEJO_NAMESPACE/$FORGEJO_ADMIN_SECRET, keys username and password (README, step 3)"
}

curl_quote() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# forgejo_api METHOD PATH [JSON]: calls the API as the admin (basic auth, given to
# curl as a config file, the body on its standard input: neither on its command
# line); FORGEJO_STATUS is the HTTP status, the body is in FORGEJO_BODY.
forgejo_api() { forgejo_api_as "$FORGEJO_USER" "$FORGEJO_PASSWORD" "$@"; }

# forgejo_api_as USER PASSWORD METHOD PATH [JSON]: forgejo_api, as USER.
forgejo_api_as() {
  local user="$1" password="$2" data=()
  shift 2
  [[ -z "${3:-}" ]] || data=(--data-binary @-)
  FORGEJO_STATUS="$(printf '%s' "${3:-}" | curl -sS -o "$FORGEJO_BODY" -w '%{http_code}' -X "$1" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -K <(printf 'user = "%s:%s"\n' "$(curl_quote "$user")" "$(curl_quote "$password")") \
    "${data[@]}" "$FORGEJO/api/v1$2")" || FORGEJO_STATUS=000
}

# forgejo_list PATH: every item of a list of the API (all its pages), as the admin,
# one JSON array on stdout; fails (forgejo_fail) on an error.
forgejo_list() {
  local sep='?' page=1 all='[]' n
  [[ "$1" != *'?'* ]] || sep='&'
  while :; do
    forgejo_api GET "$1${sep}limit=50&page=$page"
    [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot list $1"
    n="$(jq 'length' "$FORGEJO_BODY")"
    all="$(jq -c --argjson a "$all" '$a + .' "$FORGEJO_BODY")"
    (( n == 50 )) || break
    page=$((page + 1))
  done
  printf '%s\n' "$all"
}

forgejo_fail() { # MESSAGE
  echo "$PROG: $1: HTTP $FORGEJO_STATUS $(jq -r '.message? // empty' "$FORGEJO_BODY" 2>/dev/null || true)" >&2
  exit 1
}

# forgejo_ensure_org OWNER: the organization, created public if missing.
declare -A FORGEJO_ORGS=()
forgejo_ensure_org() {
  [[ -z "${FORGEJO_ORGS[$1]:-}" ]] || return 0
  FORGEJO_ORGS[$1]=1
  if $DRY_RUN; then dry "organization $1: created (public) if missing"; return; fi
  forgejo_api GET "/orgs/$1"
  case "$FORGEJO_STATUS" in
    200) ;;
    404)
      forgejo_api POST /orgs "$(jq -cn --arg o "$1" '{username: $o, visibility: "public"}')"
      [[ "$FORGEJO_STATUS" == 201 ]] \
        || forgejo_fail "cannot create the organization $1 (a user of that name, e.g. the admin of an older sandbox?)"
      echo "organization $1: created"
      ;;
    *) forgejo_fail "organization $1" ;;
  esac
}

# forgejo_ensure_repo OWNER NAME DESCRIPTION: the repository, created private and
# empty if missing, made private if an older sandbox created it public.
forgejo_ensure_repo() {
  if $DRY_RUN; then dry "repository $1/$2: created (private) if missing"; return; fi
  forgejo_api GET "/repos/$1/$2"
  case "$FORGEJO_STATUS" in
    200)
      if [[ "$(jq -r '.private' "$FORGEJO_BODY")" != true ]]; then
        forgejo_api PATCH "/repos/$1/$2" '{"private": true}'
        [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot make the repository $1/$2 private"
        echo "repository $1/$2: made private"
      fi
      ;;
    404)
      forgejo_api POST "/orgs/$1/repos" "$(jq -cn --arg n "$2" --arg d "$3" \
        '{name: $n, description: $d, private: true, default_branch: "main"}')"
      [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the repository $1/$2"
      echo "repository $1/$2: created"
      ;;
    *) forgejo_fail "repository $1/$2" ;;
  esac
}

forgejo_repo_url() { echo "$FORGEJO/$1/$2.git"; }

# forgejo_set_actions OWNER NAME true|false: Forgejo Actions on for the output
# repository (its workflow is the CI), off for a repository of the sources (no
# workflow of it runs, whatever a writer pushes), also for a repository an older
# sandbox created otherwise.
forgejo_set_actions() {
  if $DRY_RUN; then dry "repository $1/$2: Actions $($3 && echo enabled || echo disabled)"; return; fi
  forgejo_api PATCH "/repos/$1/$2" "$(jq -cn --argjson a "$3" '{has_actions: $a}')"
  [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot set Actions ($3) in the repository $1/$2"
}

# forgejo_git ARGS...: git with the admin's credentials (forgejo_git_as).
forgejo_git() { forgejo_git_as "$FORGEJO_USER" "$FORGEJO_PASSWORD" "$@"; }

# forgejo_git_as USER PASSWORD ARGS...: git with the credentials of USER
# (GIT_ASKPASS), no credential helper, and an identity for the commits it writes when
# none is configured.
forgejo_git_as() {
  local user="$1" password="$2"
  shift 2
  GIT_ASKPASS="$FORGEJO_ASKPASS" GIT_TERMINAL_PROMPT=0 \
    OKDP_FORGEJO_USER="$user" OKDP_FORGEJO_PASSWORD="$password" \
    GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config user.name || echo okdp-sandbox)}" \
    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo okdp-sandbox@okdp.io)}" \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git config user.name || echo okdp-sandbox)}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git config user.email || echo okdp-sandbox@okdp.io)}" \
    git -c credential.helper= "$@"
}

# forgejo_push_ref SRC REV REF OWNER NAME [--force]: pushes commit REV of the Git
# repository SRC as REF (refs/heads/<b> or refs/tags/<t>) of OWNER/NAME.
forgejo_push_ref() {
  local src="$1" rev="$2" ref="$3" url commit force=()
  url="$(forgejo_repo_url "$4" "$5")"
  [[ "${6:-}" != --force ]] || force=(--force)
  commit="$(git -C "$src" rev-parse --verify "$rev^{commit}")"
  if $DRY_RUN; then dry "push $src $rev (${commit:0:12}) to $4/$5 $ref ${force[*]}"; return; fi
  [[ "$(git -C "$src" rev-parse --is-shallow-repository)" == false ]] \
    || die "$src is a shallow clone: Forgejo refuses its history (clone it without --depth)"
  forgejo_git -C "$src" push -q "${force[@]}" "$url" "$commit:$ref"
  echo "pushed $4/$5 $ref (${commit:0:12})"
}

# forgejo_push_tree DIR OWNER NAME MESSAGE [--force] [--as-ci]: makes the files of
# DIR the content of branch main of OWNER/NAME: one commit on top of its main (none
# when nothing changed), whose history is kept. MESSAGE starts with "okdp-sandbox ":
# when main has, since its last such commit, a commit other than the CI's ("okdp:
# compile", forgejo/forgejo-runner: the compile of the sources), someone committed
# since the last push (the console, a person), and the push is refused, unless
# --force (their changes are then replaced). --as-ci pushes as FORGEJO_CI with its
# token (forgejo_ci_token first), the only account the output repository's main takes
# a push of (forgejo_protect_branch); else as the admin. A push that loses the race
# against the CI (a scheduled compile) is made again on top of the CI's commit.
forgejo_push_tree() {
  local dir="$1" owner="$2" name="$3" message="$4" forced=false user password
  local url repo tree commit other attempt parent=()
  shift 4
  user="$FORGEJO_USER"; password="$FORGEJO_PASSWORD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) forced=true ;;
      --as-ci) user="$FORGEJO_CI"; password="${FORGEJO_CI_TOKEN:-}" ;;
      *) die "forgejo_push_tree: unknown option $1" ;;
    esac
    shift
  done
  url="$(forgejo_repo_url "$owner" "$name")"
  if $DRY_RUN; then dry "push $dir as the content of $owner/$name main ($(find "$dir" -type f | wc -l) files), as $user"; return; fi
  repo="$WORK/git/$name"
  for attempt in 1 2 3; do
    rm -rf "$repo"; git init -q "$repo"; parent=()
    if forgejo_git_as "$user" "$password" -C "$repo" fetch -q "$url" "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null; then
      parent=(-p refs/remotes/origin/main)
      other="$(git -C "$repo" log --format=%s refs/remotes/origin/main \
        | awk '/^okdp-sandbox / {exit} $0 != "okdp: compile" {print; exit}')"
      [[ -z "$other" ]] || $forced \
        || die "$owner/$name main has commits made elsewhere since the last push (\"$other\": the console?): bring them into this repository first, or --force to replace them"
    fi
    GIT_INDEX_FILE="$repo/.git/okdp.index" git -C "$dir" --git-dir="$repo/.git" --work-tree="$dir" add -A
    tree="$(GIT_INDEX_FILE="$repo/.git/okdp.index" git --git-dir="$repo/.git" write-tree)"
    if [[ ${#parent[@]} -gt 0 && "$(git -C "$repo" rev-parse 'refs/remotes/origin/main^{tree}')" == "$tree" ]]; then
      echo "$owner/$name: up to date"
      return
    fi
    commit="$(forgejo_git_as "$user" "$password" -C "$repo" commit-tree "$tree" "${parent[@]}" -m "$message")"
    if forgejo_git_as "$user" "$password" -C "$repo" push -q "$url" "$commit:refs/heads/main" 2>"$WORK/push.log"; then
      echo "pushed $owner/$name main (${commit:0:12})"
      return
    fi
    echo "$owner/$name: the push was refused (main moved during the push, the CI?), pushing again on top of it" >&2
    sleep 2
  done
  cat "$WORK/push.log" >&2
  die "cannot push $owner/$name main as $user: refused three times (it keeps moving, or its branch protection refuses $user)"
}

# forgejo_output_workflow DIR TOPOLOGY: the CI, the workflow of the output repository
# whose content is DIR, the only workflow of the topology (okdp-gitops workflow --for
# output; the repositories of the sources hold none): every 2 minutes, and when
# dispatched, a job of the runner okdp-gitops (forgejo/forgejo-runner, registered for
# the output repository only), a new container of the okdp-gitops image, runs
# okdp-gitops compile of the topology file TOPOLOGY, which the workflow carries (the
# runner has none), with the output repository's secret OKDP_GITOPS_TOKEN, the only
# token of the CI (forgejo_ci_token): it reads the sources and writes the output, over
# https:// at CI_FORGEJO_URL (the job trusts the platform's CA bundle, CI_CA_FILE), and
# over http:// only to the hosts of CI_INSECURE_HTTP_HOSTS (none by default), the job's
# environment carrying them. A run whose sources did not move since the last
# compile (sources.yaml of the output) stops early; no push starts a run.
forgejo_output_workflow() {
  mkdir -p "$1/.forgejo/workflows"
  GITOPS_INSECURE_HTTP_HOSTS="$CI_INSECURE_HTTP_HOSTS" GITOPS_RUNNER_CA_FILE="$CI_CA_FILE" \
    "${OKDP_GITOPS:-okdp-gitops}" workflow --for output \
    --config "$2" >"$1/.forgejo/workflows/okdp-gitops.yaml"
}

# forgejo_push_catalogs: copies each catalog of catalogs.yaml that lives on
# this Forgejo (its url) from its source (catalog_origin: a checkout, pushed at the
# catalog's ref, or a Git URL), at the same ref, a commit (catalogs.yaml pins one)
# pushed as the copy's main, where the CI and the console fetch it by its hash;
# forced, the copy follows its source. A catalog elsewhere is left alone (the server
# reads it from its url).
forgejo_push_catalogs() {
  local name url ref kind src base path owner repo commit target clone
  base="$CI_FORGEJO_URL"
  while IFS=$'\t' read -r name url ref; do
    if [[ "$url" != "$base/"* ]]; then
      echo "catalog $name: $url is not on this Forgejo, not copied"
      continue
    fi
    path="${url#"$base"/}"; path="${path%.git}"; owner="${path%%/*}"; repo="${path#*/}"
    read -r kind src <<<"$(catalog_origin "$name")"
    forgejo_ensure_org "$owner"
    forgejo_ensure_repo "$owner" "$repo" "OKDP service catalog $name, copied from $src"
    FORGEJO_CATALOG_REPOS+=("$owner/$repo")
    if [[ "$kind" == url ]]; then
      clone="$WORK/catalog-sources/$name"
      if $DRY_RUN; then dry "fetch $ref of $src, push it to $owner/$repo"; continue; fi
      if catalog_ref_is_commit "$ref"; then
        catalog_fetch "$src" "$ref" "$clone" \
          || die "catalog $name: cannot fetch the commit $ref of $src (--catalog $name=DIR|URL)"
      else
        rm -rf "$clone"
        git clone -q --bare --single-branch --branch "$ref" "$src" "$clone" \
          || die "catalog $name: cannot clone $ref of $src (--catalog $name=DIR|URL)"
      fi
      src="$clone"
    fi
    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "catalog $name: $src is not a Git repository, cannot push it"
    commit="$(catalog_commit "$src" "$ref")" || die "catalog $name: no $ref in $src"
    if catalog_ref_is_commit "$ref"; then
      target=refs/heads/main
    elif git -C "$src" show-ref -q --verify "refs/tags/$ref"; then
      target="refs/tags/$ref"
    else
      target="refs/heads/$ref"
    fi
    forgejo_push_ref "$src" "$commit" "$target" "$owner" "$repo" --force
  done < <(catalog_list)
}

# forgejo_register_runner OWNER REPOSITORY: the CI runner (forgejo/forgejo-runner, the
# bootstrap's), registered in Forgejo for the output repository OWNER/REPOSITORY only,
# never for a repository of the sources nor for the organization (whose other
# repositories, the sources and the catalogs among them, would run their workflows
# on it), with the label okdp-gitops: the offline registration of forgejo-cli, in the
# Forgejo pod, with the secret the runner connects with, the key REPOSITORY of its
# Secret registrationSecret.name, in its namespace only: kept when it is there, else
# a new random one. Registering it again changes nothing. The Secret holds that key
# only (an older sandbox's registrations of the sources dropped); the runner reads it
# at start (its pod waits for the Secret): a change of its keys restarts it.
forgejo_register_runner() {
  local owner="$1" namespace name repo secret keys=() before after
  shift
  namespace="$RUNNER_NAMESPACE"
  bootstrap_resolve
  name="$(yq '.registrationSecret.name' "$BOOTSTRAP/forgejo-runner/values.yaml")"
  if $DRY_RUN; then
    dry "runner okdp-gitops (label okdp-gitops): registered in Forgejo for ${*/#/$owner/} only, its secret in Secret $namespace/$name (key ${*})"
    return
  fi
  before="$(kubectl -n "$namespace" get secret "$name" -o json 2>/dev/null | jq -r '.data // {} | keys | join(",")' || true)"
  for repo in "$@"; do
    if ! secret="$(secret_value "$namespace" "$name" "$repo")" || [[ ! "$secret" =~ ^[0-9a-f]{40}$ ]]; then
      secret="$(random_hex 20)"
    fi
    printf '%s' "$secret" | kubectl -n "$FORGEJO_NAMESPACE" exec -i "deploy/$FORGEJO_DEPLOYMENT" -c forgejo -- \
      forgejo forgejo-cli actions register --name okdp-gitops --scope "$owner/$repo" --labels okdp-gitops \
      --secret-stdin - >/dev/null \
      || die "cannot register the CI runner in Forgejo for $owner/$repo (forgejo forgejo-cli actions register)"
    keys+=("$repo=$secret")
  done
  # The Secret replaced, not merged: the keys of the repositories registered, nothing
  # else (an older sandbox's organization-wide registration, key secret, is dropped).
  kubectl -n "$namespace" delete secret "$name" --ignore-not-found >/dev/null
  secret_write "$namespace" "$name" "${keys[@]}"
  after="$(printf '%s\n' "$@" | sort | paste -sd, -)"
  echo "runner okdp-gitops: registered for ${*/#/$owner/}, its secrets in Secret $namespace/$name"
  if [[ -n "$before" && "$before" != "$after" ]] \
    && kubectl -n "$namespace" get deployment "$RUNNER_DEPLOYMENT" >/dev/null 2>&1; then
    kubectl -n "$namespace" rollout restart deployment "$RUNNER_DEPLOYMENT" >/dev/null
    echo "runner $namespace/$RUNNER_DEPLOYMENT: restarted (its repositories changed)"
  fi
}

# forgejo_user NAME DESCRIPTION: the account NAME, created if missing, never an admin
# (made one no longer if it was), with a new random password, kept for this run only
# in FORGEJO_PASSWORDS (forgejo_token creates its tokens with it), written nowhere:
# the account signs in with its tokens only. Its previous tokens are deleted: it has
# none but the ones this run creates.
declare -A FORGEJO_PASSWORDS=()
forgejo_user() {
  local user="$1" password tokens t
  if $DRY_RUN; then dry "user $user (not an admin; $2): created if missing, a new random password nobody keeps, its previous tokens deleted"; return; fi
  password="$(random_hex 24)"
  forgejo_api GET "/users/$user"
  case "$FORGEJO_STATUS" in
    404)
      forgejo_api POST /admin/users "$(jq -cn --arg u "$user" --arg p "$password" --arg d "$2" \
        '{username: $u, email: ($u + "@okdp.io"), full_name: $d, password: $p, must_change_password: false, visibility: "private"}')"
      [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the user $user"
      echo "user $user: created"
      ;;
    200)
      forgejo_api PATCH "/admin/users/$user" "$(jq -cn --arg u "$user" --arg p "$password" --arg d "$2" \
        '{login_name: $u, source_id: 0, full_name: $d, password: $p, must_change_password: false, admin: false}')"
      [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot update the user $user"
      ;;
    *) forgejo_fail "user $user" ;;
  esac
  FORGEJO_PASSWORDS[$user]="$password"
  forgejo_api_as "$user" "$password" GET "/users/$user/tokens?limit=50"
  [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot list the tokens of $user"
  tokens="$(jq -r '.[].name' "$FORGEJO_BODY")"
  for t in $tokens; do
    forgejo_api_as "$user" "$password" DELETE "/users/$user/tokens/$t"
    [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $t of $user"
  done
}

# forgejo_token USER NAME SCOPE...: FORGEJO_TOKEN, a new access token NAME of USER
# (forgejo_user first) with these scopes only.
forgejo_token() {
  local user="$1" name="$2" password
  shift 2
  password="${FORGEJO_PASSWORDS[$user]:-}"
  [[ -n "$password" ]] || die "forgejo_token: no password of $user in this run (forgejo_user first)"
  forgejo_api_as "$user" "$password" DELETE "/users/$user/tokens/$name"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $name of $user"
  forgejo_api_as "$user" "$password" POST "/users/$user/tokens" \
    "$(jq -cn --arg n "$name" '{name: $n, scopes: $ARGS.positional}' --args "$@")"
  [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the token $name of $user"
  FORGEJO_TOKEN="$(jq -r '.sha1' "$FORGEJO_BODY")"
  rm -f "$FORGEJO_BODY"
}

# forgejo_team OWNER NAME PERMISSION CREATE DESCRIPTION MEMBER REPOSITORY...: the team
# NAME of the organization OWNER, created or updated: PERMISSION (read, write) on the
# code of REPOSITORY... (names of OWNER's repositories) exactly, its other
# repositories removed, or with the single REPOSITORY "*" on every repository of OWNER
# (those created later included); never another unit; with CREATE=true, may create
# repositories. MEMBER is its only member (its other members removed), or "" for a
# team of people, whose members Forgejo keeps from their Keycloak groups.
forgejo_team() {
  local owner="$1" name="$2" permission="$3" create="$4" description="$5" member="$6"
  local all=false body team list m r
  shift 6
  if [[ "$*" == "*" ]]; then all=true; set --; fi
  if $DRY_RUN; then
    dry "team $name of $owner: $permission on $($all && echo "every repository of $owner" || echo "${*:-no repository}")$($create && echo ', may create repositories')${member:+, its only member $member}"
    return
  fi
  body="$(jq -cn --arg n "$name" --arg d "$description" --arg p "$permission" --argjson c "$create" --argjson a "$all" \
    '{name: $n, description: $d, permission: $p, includes_all_repositories: $a,
      can_create_org_repo: $c, units: ["repo.code"], units_map: {"repo.code": $p}}')"
  list="$(forgejo_list "/orgs/$owner/teams")" || exit 1
  team="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$list")"
  if [[ -z "$team" ]]; then
    forgejo_api POST "/orgs/$owner/teams" "$body"
    [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the team $name of $owner"
    team="$(jq -r '.id' "$FORGEJO_BODY")"
  else
    forgejo_api PATCH "/teams/$team" "$body"
    [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot update the team $name of $owner"
  fi
  if [[ -n "$member" ]]; then
    forgejo_api PUT "/teams/$team/members/$member"
    [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot add $member to the team $name"
    list="$(forgejo_list "/teams/$team/members")" || exit 1
    for m in $(jq -r '.[].login' <<<"$list"); do
      [[ "$m" != "$member" ]] || continue
      forgejo_api DELETE "/teams/$team/members/$m"
      [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot remove $m from the team $name"
      echo "team $name: $m removed (its only member is $member)"
    done
  fi
  $all && return 0
  for r in "$@"; do
    forgejo_api PUT "/teams/$team/repos/$owner/$r"
    [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot give the team $name $permission access to $owner/$r"
  done
  list="$(forgejo_list "/teams/$team/repos")" || exit 1
  for r in $(jq -r '.[].name' <<<"$list"); do
    one_of "$r" "$@" && continue
    forgejo_api DELETE "/teams/$team/repos/$owner/$r"
    [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot remove $owner/$r from the team $name"
    echo "team $name: $owner/$r removed"
  done
}

# forgejo_delete_team OWNER NAME: the team NAME of OWNER deleted, if it exists.
forgejo_delete_team() {
  local list team
  list="$(forgejo_list "/orgs/$1/teams")" || exit 1
  team="$(jq -r --arg n "$2" '.[] | select(.name == $n) | .id' <<<"$list")"
  [[ -n "$team" ]] || return 0
  forgejo_api DELETE "/teams/$team"
  [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot delete the team $2 of $1"
  echo "team $2 of $1: deleted"
}

# forgejo_delete_user NAME: the account NAME deleted, if it exists, with its tokens,
# its memberships and its collaborations (purge), unless it owns repositories (it
# never should: the repositories are the organization's).
forgejo_delete_user() {
  forgejo_api GET "/users/$1"
  [[ "$FORGEJO_STATUS" == 200 ]] || return 0
  forgejo_api GET "/users/$1/repos?limit=1"
  [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot list the repositories of $1"
  [[ "$(jq 'length' "$FORGEJO_BODY")" == 0 ]] \
    || die "the user $1 owns repositories: move them to the organization, then run again"
  forgejo_api DELETE "/admin/users/$1?purge=true"
  [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot delete the user $1"
  echo "user $1: deleted, with its tokens and memberships"
}

# forgejo_console_enabled: the layout installs the control plane (the instance
# okdp-control-plane-server, whose values are SERVER_VALUES): the console account
# exists then only.
forgejo_console_enabled() { [[ -f "$(dirname "$SERVER_VALUES")/instance.yaml" ]]; }

# forgejo_legacy_cleanup OWNER: an older sandbox's single account FORGEJO_LEGACY_BOT
# (the console's, by password, the CI's and the engines' at once) deleted with its
# tokens and memberships (forgejo_delete_user), its teams FORGEJO_LEGACY_TEAMS of
# OWNER, the admin's former token of the server, and the Secrets of its credentials:
# the runner's copy and the console's former Secret (FORGEJO_LEGACY_CONSOLE_SECRET).
forgejo_legacy_cleanup() {
  local owner="$1" t
  if $DRY_RUN; then
    dry "user $FORGEJO_LEGACY_BOT of an older sandbox (the console, the CI and the engines at once): deleted with its tokens and memberships, its teams ${FORGEJO_LEGACY_TEAMS[*]} of $owner too"
    return
  fi
  forgejo_delete_user "$FORGEJO_LEGACY_BOT"
  for t in "${FORGEJO_LEGACY_TEAMS[@]}"; do forgejo_delete_team "$owner" "$t"; done
  forgejo_api DELETE "/users/$FORGEJO_USER/tokens/okdp-control-plane-server"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] \
    || forgejo_fail "cannot delete the token okdp-control-plane-server of $FORGEJO_USER"
  kubectl -n "$RUNNER_NAMESPACE" delete secret "$FORGEJO_LEGACY_CONSOLE_SECRET" --ignore-not-found >/dev/null
  if [[ "$(yq '.gitops.credentialsSecret // ""' "$SERVER_VALUES")" != "$FORGEJO_LEGACY_CONSOLE_SECRET" ]]; then
    kubectl -n "$SERVER_NAMESPACE" delete secret "$FORGEJO_LEGACY_CONSOLE_SECRET" --ignore-not-found >/dev/null
  fi
}

# forgejo_accounts OWNER CREATE OUTPUT SOURCE...: the accounts of the topology
# (forgejo_user), each the only member of its teams of OWNER (forgejo_team), an older
# sandbox's single account removed first (forgejo_legacy_cleanup):
#   FORGEJO_CI       team okdp-ci: write, OUTPUT only; team okdp-ci-read: read, the
#                    SOURCEs and the catalogs of OWNER copied to Forgejo
#                    (FORGEJO_CATALOG_REPOS, forgejo_push_catalogs first), or, with
#                    CREATE=true (split), every repository of OWNER: the repository
#                    the console creates for a new project is read at the next run.
#   FORGEJO_READER   team okdp-reader: read, OUTPUT only.
#   FORGEJO_CONSOLE  (forgejo_console_enabled) team okdp-console: write, the SOURCEs,
#                    and, with CREATE=true, may create repositories (a new project's:
#                    the console is then their admin); team okdp-console-read: read,
#                    OUTPUT (the compiled tree the console shows) and the catalogs.
#                    Never a writer of OUTPUT. Without the control plane, the account
#                    and its teams are deleted, and its Secrets (the server's values'
#                    gitops.credentialsSecret and gitops.forgejoTokenSecret).
# None writes the platform's and the projects' repositories but the console; people
# get their teams from their Keycloak groups.
forgejo_accounts() {
  local owner="$1" create="$2" output="$3" c catalogs=() read=() secret
  shift 3
  for c in "${FORGEJO_CATALOG_REPOS[@]}"; do
    if [[ "${c%%/*}" == "$owner" ]]; then
      catalogs+=("${c#*/}")
    else
      echo "catalog $c: not of the organization $owner, the CI and the console get no read access to it" >&2
    fi
  done
  forgejo_legacy_cleanup "$owner"
  if $create; then read=("*"); else read=("$@" "${catalogs[@]}"); fi
  forgejo_user "$FORGEJO_CI" "the CI of $owner/$output, its only pusher"
  forgejo_team "$owner" "$FORGEJO_CI" write false \
    "The CI: writes the output repository, the only pusher of its main" "$FORGEJO_CI" "$output"
  forgejo_team "$owner" "$FORGEJO_CI-read" read false \
    "The CI: reads the sources and the service catalogs" "$FORGEJO_CI" "${read[@]}"
  forgejo_user "$FORGEJO_READER" "Argo CD and Flux, readers of $owner/$output"
  forgejo_team "$owner" "$FORGEJO_READER" read false \
    "Argo CD and Flux: read the output repository" "$FORGEJO_READER" "$output"
  if forgejo_console_enabled; then
    forgejo_user "$FORGEJO_CONSOLE" "the control plane, a writer of the sources"
    forgejo_team "$owner" "$FORGEJO_CONSOLE" write "$create" \
      "The control plane: writes the sources, never the output" "$FORGEJO_CONSOLE" "$@"
    forgejo_team "$owner" "$FORGEJO_CONSOLE-read" read false \
      "The control plane: reads the output repository and the service catalogs" "$FORGEJO_CONSOLE" "$output" "${catalogs[@]}"
  elif $DRY_RUN; then
    dry "no control plane in the layout: user $FORGEJO_CONSOLE, its teams and its Secrets deleted"
  else
    forgejo_delete_user "$FORGEJO_CONSOLE"
    forgejo_delete_team "$owner" "$FORGEJO_CONSOLE"
    forgejo_delete_team "$owner" "$FORGEJO_CONSOLE-read"
    for secret in "$(yq '.gitops.credentialsSecret // ""' "$SERVER_VALUES")" \
      "$(yq '.gitops.forgejoTokenSecret // ""' "$SERVER_VALUES")"; do
      [[ -z "$secret" ]] || kubectl -n "$SERVER_NAMESPACE" delete secret "$secret" --ignore-not-found >/dev/null
    done
  fi
}

# forgejo_ci_token OWNER OUTPUT_REPO SOURCE_REPO...: the token of the CI, the only
# one: an access token of FORGEJO_CI (forgejo_accounts first; write:repository),
# replaced at each push, in the Actions secret OKDP_GITOPS_TOKEN of the output
# repository only, whose workflow reads the sources and writes the output with it,
# and FORGEJO_CI_TOKEN, with which this run pushes the output (forgejo_push_tree
# --as-ci). Whoever can push a workflow to a repository can read its secrets: the
# repositories of the sources, which every writer of the tree pushes to, hold none;
# an older sandbox's secrets there (OKDP_GITOPS_TOKEN, OKDP_DISPATCH_TOKEN) are
# deleted.
forgejo_ci_token() {
  local owner="$1" output="$2" repo secret
  shift 2
  if $DRY_RUN; then
    dry "access token okdp-ci of $FORGEJO_CI (write:repository) -> Actions secret OKDP_GITOPS_TOKEN of $owner/$output"
    dry "Actions secrets OKDP_GITOPS_TOKEN and OKDP_DISPATCH_TOKEN of ${*/#/$owner/}: deleted"
    return
  fi
  forgejo_token "$FORGEJO_CI" okdp-ci write:repository
  FORGEJO_CI_TOKEN="$FORGEJO_TOKEN"
  forgejo_api PUT "/repos/$owner/$output/actions/secrets/OKDP_GITOPS_TOKEN" "$(jq -cn --arg t "$FORGEJO_CI_TOKEN" '{data: $t}')"
  [[ "$FORGEJO_STATUS" == 201 || "$FORGEJO_STATUS" == 204 ]] \
    || forgejo_fail "cannot write the Actions secret OKDP_GITOPS_TOKEN of $owner/$output"
  echo "Actions secret OKDP_GITOPS_TOKEN of $owner/$output: the access token okdp-ci of $FORGEJO_CI"
  # An older sandbox's: the token in the sources, the dispatch token.
  for repo in "$@"; do
    for secret in OKDP_GITOPS_TOKEN OKDP_DISPATCH_TOKEN; do
      forgejo_api DELETE "/repos/$owner/$repo/actions/secrets/$secret"
      [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] \
        || forgejo_fail "cannot delete the Actions secret $secret of $owner/$repo"
    done
  done
  echo "repositories of the sources ${*/#/$owner/}: no Actions secret"
}

# forgejo_console_secrets SPLIT: the console's credentials (forgejo_console_enabled;
# forgejo_accounts first), in the server's namespace only, never a password: an
# access token okdp-console-git of FORGEJO_CONSOLE (write:repository), the password
# of the user FORGEJO_CONSOLE in the Secret gitops.credentialsSecret of the server's
# values (keys username, password: the server's git credentials, a token as
# password); with SPLIT=true, an access token okdp-console-api (write:organization,
# write:repository: it creates the repository of a new project) in the Secret
# gitops.forgejoTokenSecret (key token).
forgejo_console_secrets() {
  local creds api
  forgejo_console_enabled || return 0
  creds="$(yq '.gitops.credentialsSecret // ""' "$SERVER_VALUES")"
  api="$(yq '.gitops.forgejoTokenSecret // ""' "$SERVER_VALUES")"
  [[ -n "$creds" ]] || die "no gitops.credentialsSecret in ${SERVER_VALUES#"$ROOT"/}: the Secret of the console's Forgejo token"
  if $DRY_RUN; then
    dry "access token okdp-console-git of $FORGEJO_CONSOLE (write:repository) -> Secret $SERVER_NAMESPACE/$creds (username, password)"
    if $1; then dry "access token okdp-console-api of $FORGEJO_CONSOLE (write:organization, write:repository) -> Secret $SERVER_NAMESPACE/$api (token)"; fi
    return
  fi
  forgejo_token "$FORGEJO_CONSOLE" okdp-console-git write:repository
  secret_write "$SERVER_NAMESPACE" "$creds" "username=$FORGEJO_CONSOLE" "password=$FORGEJO_TOKEN"
  echo "Secret $SERVER_NAMESPACE/$creds: the access token okdp-console-git of $FORGEJO_CONSOLE"
  if $1; then
    [[ -n "$api" ]] || die "no gitops.forgejoTokenSecret in ${SERVER_VALUES#"$ROOT"/} (split: scripts/configure.sh --topology split)"
    forgejo_token "$FORGEJO_CONSOLE" okdp-console-api write:organization write:repository
    secret_write "$SERVER_NAMESPACE" "$api" "token=$FORGEJO_TOKEN"
    echo "Secret $SERVER_NAMESPACE/$api: the access token okdp-console-api of $FORGEJO_CONSOLE"
  else
    [[ -z "$api" ]] || kubectl -n "$SERVER_NAMESPACE" delete secret "$api" --ignore-not-found >/dev/null
  fi
}

# forgejo_protect_branch OWNER REPO BRANCH: branch protection on BRANCH of the output
# repository: the push whitelist is FORGEJO_CI alone (the CI's token, its account:
# forgejo_accounts first, Forgejo keeps on the whitelist the users that write to the
# repository only), applied to the administrators too (the admin, the organization's
# owners: the platform admins), no force push (Forgejo refuses one on a protected
# branch), no deletion. Nobody else pushes there, the admin and the console included:
# a writer of the output deploys anything, past every check of the compile.
forgejo_protect_branch() {
  local body
  if $DRY_RUN; then dry "branch protection on $1/$2 $3: push whitelist $FORGEJO_CI, the administrators included, no force push"; return; fi
  body="$(jq -cn --arg b "$3" --arg u "$FORGEJO_CI" '{branch_name: $b, rule_name: $b,
    enable_push: true, enable_push_whitelist: true, push_whitelist_usernames: [$u],
    push_whitelist_teams: [], push_whitelist_deploy_keys: false, apply_to_admins: true,
    enable_status_check: false, block_on_rejected_reviews: false}')"
  forgejo_api POST "/repos/$1/$2/branch_protections" "$body"
  case "$FORGEJO_STATUS" in
    201) echo "branch protection on $1/$2 $3: created" ;;
    403|409|422) # already exists: update it
      forgejo_api PATCH "/repos/$1/$2/branch_protections/$3" "$(jq -c 'del(.branch_name, .rule_name)' <<<"$body")"
      [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot update branch protection on $1/$2 $3"
      echo "branch protection on $1/$2 $3: updated" ;;
    *) forgejo_fail "cannot create branch protection on $1/$2 $3" ;;
  esac
  [[ "$(jq -c --arg u "$FORGEJO_CI" '[.enable_push, .enable_push_whitelist, .push_whitelist_usernames == [$u], .apply_to_admins]' "$FORGEJO_BODY")" == '[true,true,true,true]' ]] \
    || die "branch protection on $1/$2 $3: the push whitelist is not $FORGEJO_CI alone, or the administrators are exempt ($(jq -c '[.push_whitelist_usernames, .apply_to_admins]' "$FORGEJO_BODY"))"
}

# forgejo_engine_secrets [NAMESPACE SECRET]...: the engines' (Argo CD, Flux) access
# token okdp-engines of FORGEJO_READER (forgejo_accounts first; read:repository), who
# reads the output repository only, written to each NAMESPACE/SECRET (keys username,
# password).
forgejo_engine_secrets() {
  if $DRY_RUN; then
    while [[ $# -ge 2 ]]; do dry "Secret $1/$2: the access token okdp-engines of $FORGEJO_READER (read:repository)"; shift 2; done
    return
  fi
  forgejo_token "$FORGEJO_READER" okdp-engines read:repository
  while [[ $# -ge 2 ]]; do
    secret_write "$1" "$2" "username=$FORGEJO_READER" "password=$FORGEJO_TOKEN"
    echo "Secret $1/$2: the access token okdp-engines of $FORGEJO_READER (read:repository)"
    shift 2
  done
}

# ------------------------------------------------------------------- people
# People sign in with Keycloak (the OAuth source keycloak, forgejo_sign_in): their
# Keycloak groups (the groups claim) give their teams, Forgejo keeping their
# membership at each sign-in (--group-team-map, --group-team-map-removal). The groups
# and their roles are the platform's (global.okdp.access.admins of platform.yaml)
# and each project's (its project.yaml access), read from what the compile wrote,
# never decided here: the AppProject project-<p> of the compiled tree, its roles'
# groups.

# FORGEJO_GROUP_TEAMS: group -> the teams of OWNER its members join (space separated),
# filled by forgejo_people_teams.
declare -A FORGEJO_GROUP_TEAMS=()
forgejo_group_team() { FORGEJO_GROUP_TEAMS[$1]="${FORGEJO_GROUP_TEAMS[$1]:+${FORGEJO_GROUP_TEAMS[$1]} }$2"; }

# forgejo_admin_groups: the platform's administrators' groups, one per line
# (global.okdp.access.admins of platform.yaml).
forgejo_admin_groups() { yq -r '.global.okdp.access.admins[]?' "$ROOT/platform.yaml"; }

# forgejo_people_teams OWNER TOPOLOGY OUT: the teams of the people of OWNER, from the
# compiled tree OUT (layout_compile): the platform's administrators join Owners, the
# organization's owners; for each compiled project <p>, the groups of the roles
# editor and admin of its AppProject (OUT/compiled/projects/<p>/project/appproject.yaml)
# join the team okdp-project-<p>, which writes its repository (split
# okdp-project-<p>; io okdp-projects, every project's), those of viewer the team
# okdp-project-<p>-viewers, which reads it; never the platform's repository nor the
# output. A team okdp-project-* of no compiled project (a project removed, or
# without a role of that kind) is deleted. The members are Forgejo's to keep, from
# the groups claim (forgejo_sign_in): no member is set here.
forgejo_people_teams() {
  local owner="$1" topology="$2" out="$3" f p repo g list t keep=()
  for g in $(forgejo_admin_groups); do forgejo_group_team "$g" Owners; done
  for f in "$out"/compiled/projects/*/project/appproject.yaml; do
    [[ -f "$f" ]] || continue
    p="$(basename "$(dirname "$(dirname "$f")")")"
    case "$topology" in
      io) repo="$PROJECTS_REPO" ;;
      split) repo="$PROJECT_REPO_PREFIX$p" ;;
      *) die "forgejo_people_teams: topology $topology" ;;
    esac
    for t in write:editor,admin read:viewer; do
      local team="okdp-project-$p" permission="${t%%:*}" roles="${t#*:}" groups
      [[ "$permission" == write ]] || team="$team-viewers"
      # shellcheck disable=SC2016 # a yq variable
      groups="$(R="$roles" yq -r '.spec.roles[]? | select(.name as $n | strenv(R) | split(",") | any_c(. == $n)) | .groups[]?' "$f" | sort -u)"
      [[ -n "$groups" ]] || continue
      forgejo_team "$owner" "$team" "$permission" false \
        "The people of the project $p ($roles of its project.yaml access): $permission $owner/$repo" "" "$repo"
      keep+=("$team")
      for g in $groups; do forgejo_group_team "$g" "$team"; done
    done
  done
  if $DRY_RUN; then dry "teams okdp-project-* of $owner but ${keep[*]:-none}: deleted"; return; fi
  list="$(forgejo_list "/orgs/$owner/teams")" || exit 1
  for t in $(jq -r '.[].name | select(startswith("okdp-project-"))' <<<"$list"); do
    one_of "$t" "${keep[@]}" || forgejo_delete_team "$owner" "$t"
  done
}

# forgejo_group_team_map OWNER: the --group-team-map of the OAuth source,
# {"<group>": {"OWNER": ["<team>", ...]}, ...} (forgejo_people_teams first).
forgejo_group_team_map() {
  local g
  for g in "${!FORGEJO_GROUP_TEAMS[@]}"; do
    # Word splitting of the team list is intended.
    # shellcheck disable=SC2086
    jq -cn --arg g "$g" --arg o "$1" '{($g): {($o): $ARGS.positional}}' --args ${FORGEJO_GROUP_TEAMS[$g]}
  done | jq -cs 'add // {} | to_entries | sort_by(.key) | from_entries'
}

# forgejo_sign_in OWNER ADD: the OAuth source keycloak of Forgejo, the sign-in with
# the realm's client forgejo (sandbox-charts' bootstrap/keycloak/realm.yaml), its
# issuer global.okdp.oidc.issuerUri of platform.yaml, created (ADD=true) or updated
# (when it exists; else nothing, ADD=false), in Forgejo's database through its CLI in
# its pod: the admin group the platform's first administrators' group (Forgejo's
# administrators), the group-team map of forgejo_group_team_map, membership removed
# when the group is (--group-team-map-removal). The client's secret, of Secret
# keycloak/keycloak-client-secrets (the bootstrap's), reaches the pod on its standard
# input. Forgejo needs Keycloak reachable and its CA trusted (README, after step 5).
forgejo_sign_in() {
  local owner="$1" add="$2" issuer admin map id secret args
  issuer="$(yq -r '.global.okdp.oidc.issuerUri // ""' "$ROOT/platform.yaml")"
  [[ -n "$issuer" ]] || die "platform.yaml: no global.okdp.oidc.issuerUri, the issuer Forgejo signs in with"
  admin="$(forgejo_admin_groups | head -n 1)"
  [[ -n "$admin" ]] || die "platform.yaml: no global.okdp.access.admins, the platform's administrators"
  map="$(forgejo_group_team_map "$owner")"
  args=(--name keycloak --provider openidConnect --key forgejo
    --auto-discover-url "${issuer%/}/.well-known/openid-configuration"
    --group-claim-name groups --admin-group "$admin"
    --group-team-map "$map" --group-team-map-removal)
  if $DRY_RUN; then
    dry "OAuth source keycloak of Forgejo ($($add && echo 'created or updated' || echo 'updated if it exists')): $issuer, admin group $admin, group-team map $map"
    return
  fi
  id="$(kubectl -n "$FORGEJO_NAMESPACE" exec "deploy/$FORGEJO_DEPLOYMENT" -c forgejo -- forgejo admin auth list \
    | awk '$2 == "keycloak" {print $1}')"
  if [[ -z "$id" ]] && ! $add; then
    echo "OAuth source keycloak: none yet (scripts/configure.sh --push --sign-in once the platform is up)"
    return
  fi
  secret="$(secret_value keycloak keycloak-client-secrets forgejo)" && [[ -n "$secret" ]] \
    || die "no secret of the client forgejo in Secret keycloak/keycloak-client-secrets (the bootstrap's)"
  if [[ -n "$id" ]]; then args=(update-oauth --id "$id" "${args[@]}"); else args=(add-oauth "${args[@]}"); fi
  # shellcheck disable=SC2016 # expanded by the pod's shell
  printf '%s\n' "$secret" | kubectl -n "$FORGEJO_NAMESPACE" exec -i "deploy/$FORGEJO_DEPLOYMENT" -c forgejo -- \
    sh -c 'read -r secret && exec forgejo admin auth "$@" --secret "$secret"' sh "${args[@]}" >/dev/null \
    || die "cannot $( [[ -n "$id" ]] && echo update || echo create ) the OAuth source keycloak of Forgejo"
  echo "OAuth source keycloak: $( [[ -n "$id" ]] && echo updated || echo created ), $issuer, admin group $admin, group-team map $map"
}
