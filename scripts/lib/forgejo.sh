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
#
# This file holds the connection, the API, the organization, the repositories and the
# pushes; it sources, from this directory, lib/forgejo-accounts.sh (the accounts and
# their teams), lib/forgejo-ci.sh (the CI: workflow, catalogs, runner, token, branch
# protection) and lib/forgejo-people.sh (the people, signed in through Keycloak).

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

# The rest of the library, by concern, in this directory.
FORGEJO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=forgejo-accounts.sh
source "$FORGEJO_LIB/forgejo-accounts.sh"
# shellcheck source=forgejo-ci.sh
source "$FORGEJO_LIB/forgejo-ci.sh"
# shellcheck source=forgejo-people.sh
source "$FORGEJO_LIB/forgejo-people.sh"
