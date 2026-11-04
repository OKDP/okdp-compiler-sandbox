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
# organization, the repositories (private) and the account the console and the CI
# write with (forgejo_bot). The CI is the output repository's alone: its workflow
# (forgejo_output_workflow: a compile of the sources on a schedule), its Actions,
# its runner (forgejo_register_runner) and its token, the only one, in its Actions
# secret OKDP_GITOPS_TOKEN (forgejo_ci_token); the repositories of the sources hold
# no workflow, no secret and no runner, their Actions off. Branch protection on the
# output repository's main lets the bot alone push there (forgejo_protect_branch);
# the engines get a read token (forgejo_engine_secrets). Git pushes the sources with
# the admin account and the output with the bot's, through GIT_ASKPASS (never in a
# URL or on a command line). With DRY_RUN=true, nothing is called: each action is
# printed, the parts are still built in $WORK.
#
# Requires curl, jq, kubectl (port-forward, the Secrets, the runner's registration),
# git.

# The values Forgejo was installed with (default: sandbox-charts'
# bootstrap/forgejo/values.yaml of the catalog BOOTSTRAP_CATALOG, bootstrap_resolve),
# and its namespace (README, step 3).
FORGEJO_VALUES="${FORGEJO_VALUES:-}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
DRY_RUN="${DRY_RUN:-false}"
# The account the console and the CI write to the repositories of the topology with,
# and its team in the organization (forgejo_bot); its team that reads the catalogs.
FORGEJO_BOT=okdp-gitops
FORGEJO_BOT_READ_TEAM=okdp-gitops-read
# The catalogs of the organization copied to Forgejo (forgejo_push_catalogs), which
# the bot reads (forgejo_bot): the CI's compile and the console fetch them with its
# credentials, the repositories being private.
FORGEJO_CATALOG_REPOS=()

dry() { echo "[dry-run] $*"; }

# random_hex BYTES: BYTES random bytes, in hexadecimal.
random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# secret_value NAMESPACE SECRET KEY: the value of KEY of a Secret of the current
# context; fails when the Secret does not exist.
secret_value() {
  kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d
}

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
# curl as a config file, not on its command line); FORGEJO_STATUS is the HTTP
# status, the body is in FORGEJO_BODY.
forgejo_api() { forgejo_api_as "$FORGEJO_USER" "$FORGEJO_PASSWORD" "$@"; }

# forgejo_api_as USER PASSWORD METHOD PATH [JSON]: forgejo_api, as USER.
forgejo_api_as() {
  local user="$1" password="$2" data=()
  shift 2
  [[ -z "${3:-}" ]] || data=(--data "$3")
  FORGEJO_STATUS="$(curl -sS -o "$FORGEJO_BODY" -w '%{http_code}' -X "$1" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -K <(printf 'user = "%s:%s"\n' "$(curl_quote "$user")" "$(curl_quote "$password")") \
    "${data[@]}" "$FORGEJO/api/v1$2")" || FORGEJO_STATUS=000
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

# forgejo_push_tree DIR OWNER NAME MESSAGE [--force] [--as-bot]: makes the files of
# DIR the content of branch main of OWNER/NAME: one commit on top of its main (none
# when nothing changed), whose history is kept. MESSAGE starts with "okdp-sandbox ":
# when main has, since its last such commit, a commit other than the CI's ("okdp:
# compile", forgejo/forgejo-runner: the compile of the sources), someone committed
# since the last push (the console, a person), and the push is refused, unless
# --force (their changes are then replaced). --as-bot pushes as FORGEJO_BOT
# (forgejo_bot first), the only account the output repository's main takes a push of
# (forgejo_protect_branch); else as the admin. A push that loses the race against the
# CI (a scheduled compile) is made again on top of the CI's commit.
forgejo_push_tree() {
  local dir="$1" owner="$2" name="$3" message="$4" forced=false user password
  local url repo tree commit other attempt parent=()
  shift 4
  user="$FORGEJO_USER"; password="$FORGEJO_PASSWORD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) forced=true ;;
      --as-bot) user="$FORGEJO_BOT"; password="${FORGEJO_BOT_PASSWORD:-}" ;;
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
# http:// to the hosts of CI_INSECURE_HTTP_HOSTS only (the cluster's services), the
# job's environment carrying them. A run whose sources did not move since the last
# compile (sources.yaml of the output) stops early; no push starts a run.
forgejo_output_workflow() {
  mkdir -p "$1/.forgejo/workflows"
  GITOPS_INSECURE_HTTP_HOSTS="$CI_INSECURE_HTTP_HOSTS" "${OKDP_GITOPS:-okdp-gitops}" workflow --for output \
    --config "$2" >"$1/.forgejo/workflows/okdp-gitops.yaml"
}

# forgejo_push_catalogs: copies each catalog of catalogs.yaml that lives on
# this Forgejo (its url) from its source (catalog_origin: a checkout, pushed at the
# catalog's ref, or a Git URL), at the same ref; forced, the copy follows its source.
# A catalog elsewhere is left alone (the server reads it from its url).
forgejo_push_catalogs() {
  local name url ref kind src base path owner repo commit target clone
  base="$(forgejo_cluster_url)"
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
      if $DRY_RUN; then dry "clone $ref of $src, push it to $owner/$repo"; continue; fi
      rm -rf "$clone"
      git clone -q --bare --single-branch --branch "$ref" "$src" "$clone" \
        || die "catalog $name: cannot clone $ref of $src (--catalog $name=DIR|URL)"
      src="$clone"
    fi
    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "catalog $name: $src is not a Git repository, cannot push it"
    commit="$(catalog_commit "$src" "$ref")" || die "catalog $name: no $ref in $src"
    target="refs/heads/$ref"
    if git -C "$src" show-ref -q --verify "refs/tags/$ref"; then target="refs/tags/$ref"; fi
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

# forgejo_ci_token OWNER OUTPUT_REPO SOURCE_REPO...: the token of the CI, the only
# one: an access token of FORGEJO_BOT (write:repository), replaced at each push, in
# the Actions secret OKDP_GITOPS_TOKEN of the output repository only, whose workflow
# reads the sources and writes the output with it. Whoever can push a workflow to a
# repository can read its secrets: the repositories of the sources, which every
# writer of the tree pushes to, hold none; an older sandbox's secrets there
# (OKDP_GITOPS_TOKEN, OKDP_DISPATCH_TOKEN) are deleted, and its dispatch token too.
forgejo_ci_token() {
  local owner="$1" output="$2" name=okdp-gitops-ci token repo secret
  shift 2
  if $DRY_RUN; then
    dry "access token $name of $FORGEJO_BOT (write:repository) -> Actions secret OKDP_GITOPS_TOKEN of $owner/$output"
    dry "Actions secrets OKDP_GITOPS_TOKEN and OKDP_DISPATCH_TOKEN of ${*/#/$owner/}: deleted"
    return
  fi
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" DELETE "/users/$FORGEJO_BOT/tokens/$name"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $name"
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" POST "/users/$FORGEJO_BOT/tokens" "$(jq -cn --arg n "$name" \
    '{name: $n, scopes: ["write:repository"]}')"
  [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the token $name"
  token="$(jq -r '.sha1' "$FORGEJO_BODY")"
  rm -f "$FORGEJO_BODY"
  forgejo_api PUT "/repos/$owner/$output/actions/secrets/OKDP_GITOPS_TOKEN" "$(jq -cn --arg t "$token" '{data: $t}')"
  [[ "$FORGEJO_STATUS" == 201 || "$FORGEJO_STATUS" == 204 ]] \
    || forgejo_fail "cannot write the Actions secret OKDP_GITOPS_TOKEN of $owner/$output"
  echo "Actions secret OKDP_GITOPS_TOKEN of $owner/$output: the access token $name of $FORGEJO_BOT"
  # An older sandbox's: the token in the sources, the dispatch token.
  for repo in "$@"; do
    for secret in OKDP_GITOPS_TOKEN OKDP_DISPATCH_TOKEN; do
      forgejo_api DELETE "/repos/$owner/$repo/actions/secrets/$secret"
      [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] \
        || forgejo_fail "cannot delete the Actions secret $secret of $owner/$repo"
    done
  done
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" DELETE "/users/$FORGEJO_BOT/tokens/okdp-gitops-dispatch"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token okdp-gitops-dispatch"
  echo "repositories of the sources ${*/#/$owner/}: no Actions secret"
}

# forgejo_team OWNER NAME PERMISSION CREATE DESCRIPTION REPOSITORY...: the team NAME
# of the organization OWNER, created or updated: PERMISSION (read, write) on the code
# of REPOSITORY... (names of OWNER's repositories) only, never every repository, and,
# with CREATE=true, may create repositories; its member FORGEJO_BOT.
forgejo_team() {
  local owner="$1" name="$2" permission="$3" create="$4" description="$5" body team repo
  shift 5
  body="$(jq -cn --arg n "$name" --arg d "$description" --arg p "$permission" --argjson c "$create" \
    '{name: $n, description: $d, permission: $p, includes_all_repositories: false,
      can_create_org_repo: $c, units: ["repo.code"], units_map: {"repo.code": $p}}')"
  forgejo_api GET "/orgs/$owner/teams?limit=50"
  [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "teams of $owner"
  team="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' "$FORGEJO_BODY")"
  if [[ -z "$team" ]]; then
    forgejo_api POST "/orgs/$owner/teams" "$body"
    [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the team $name of $owner"
    team="$(jq -r '.id' "$FORGEJO_BODY")"
  else
    forgejo_api PATCH "/teams/$team" "$body"
    [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot update the team $name of $owner"
  fi
  forgejo_api PUT "/teams/$team/members/$FORGEJO_BOT"
  [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot add $FORGEJO_BOT to the team $name"
  for repo in "$@"; do
    forgejo_api PUT "/teams/$team/repos/$owner/$repo"
    [[ "$FORGEJO_STATUS" == 204 ]] || forgejo_fail "cannot give the team $name $permission access to $owner/$repo"
  done
}

# forgejo_bot OWNER CREATE REPOSITORY...: the account the console and the CI write to
# the repositories of the topology with, never the admin: user FORGEJO_BOT, not an
# admin, member of the team FORGEJO_BOT of the organization OWNER, which writes to
# REPOSITORY... only (the sources, the console's, and the output, the CI's: the
# output's main takes the pushes of this account only, forgejo_protect_branch) and,
# with CREATE=true (split), may create repositories (the console's project
# repositories, of which the user is then the admin), and of its team
# FORGEJO_BOT_READ_TEAM, which reads the catalogs of OWNER copied to Forgejo
# (FORGEJO_CATALOG_REPOS, forgejo_push_catalogs first): the repositories are
# private, the CI's compile and the console fetch the catalogs with its credentials.
# Its password is the one of the console's Secret (gitops.credentialsSecret of
# okdp-system/okdp-control-plane-server) when it is there, else a new random one: set
# on the account, then written, with the user name, to that Secret, in its namespace
# only. The CI has no password of it: a token, in the output repository's Actions
# secret (forgejo_ci_token).
forgejo_bot() {
  local owner="$1" create="$2" console_ns console_secret c catalogs=()
  shift 2
  console_ns="$SERVER_NAMESPACE"
  console_secret="$(yq '.gitops.credentialsSecret' "$SERVER_VALUES")"
  for c in "${FORGEJO_CATALOG_REPOS[@]}"; do
    if [[ "${c%%/*}" == "$owner" ]]; then
      catalogs+=("${c#*/}")
    else
      echo "catalog $c: not of the organization $owner, the bot gets no read access to it" >&2
    fi
  done
  if $DRY_RUN; then
    dry "user $FORGEJO_BOT (not an admin): created if missing, its password set"
    dry "team $FORGEJO_BOT of $owner: member $FORGEJO_BOT, writes to $*$($create && echo ', may create repositories')"
    dry "team $FORGEJO_BOT_READ_TEAM of $owner: member $FORGEJO_BOT, reads ${catalogs[*]}"
    dry "Secret $console_ns/$console_secret: the user name and password of $FORGEJO_BOT"
    return
  fi
  if ! FORGEJO_BOT_PASSWORD="$(secret_value "$console_ns" "$console_secret" password)" \
    || [[ -z "$FORGEJO_BOT_PASSWORD" ]]; then
    FORGEJO_BOT_PASSWORD="$(random_hex 24)"
  fi
  forgejo_api GET "/users/$FORGEJO_BOT"
  case "$FORGEJO_STATUS" in
    404)
      forgejo_api POST /admin/users "$(jq -cn --arg u "$FORGEJO_BOT" --arg p "$FORGEJO_BOT_PASSWORD" \
        '{username: $u, email: ($u + "@okdp.io"), password: $p, must_change_password: false, visibility: "private"}')"
      [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the user $FORGEJO_BOT"
      echo "user $FORGEJO_BOT: created"
      ;;
    200)
      forgejo_api PATCH "/admin/users/$FORGEJO_BOT" "$(jq -cn --arg u "$FORGEJO_BOT" --arg p "$FORGEJO_BOT_PASSWORD" \
        '{login_name: $u, source_id: 0, password: $p, must_change_password: false, admin: false}')"
      [[ "$FORGEJO_STATUS" == 200 ]] || forgejo_fail "cannot update the user $FORGEJO_BOT"
      ;;
    *) forgejo_fail "user $FORGEJO_BOT" ;;
  esac
  forgejo_team "$owner" "$FORGEJO_BOT" write "$create" \
    "The console and the CI: write to the deployments repositories" "$@"
  forgejo_team "$owner" "$FORGEJO_BOT_READ_TEAM" read false \
    "The console and the CI: read the service catalogs" "${catalogs[@]}"
  secret_write "$console_ns" "$console_secret" "username=$FORGEJO_BOT" "password=$FORGEJO_BOT_PASSWORD"
  # The runner's copy of an older sandbox (the CI's credentials before its token).
  kubectl -n "$RUNNER_NAMESPACE" delete secret okdp-gitops-bot --ignore-not-found >/dev/null
  echo "user $FORGEJO_BOT: writes to $*, reads ${catalogs[*]} of $owner, in Secret $console_ns/$console_secret"
}

# forgejo_token_secret NAMESPACE SECRET: a new access token of FORGEJO_BOT
# (forgejo_bot first) for the control plane server (it creates the project
# repositories of the split topology), in Secret NAMESPACE/SECRET, key token (the
# namespace created if missing). The previous token of that name is deleted, the
# admin's too (the server's token before FORGEJO_BOT).
forgejo_token_secret() {
  local name=okdp-control-plane-server token
  if $DRY_RUN; then
    dry "access token $name of $FORGEJO_BOT (write:organization, write:repository, read:user), replacing the previous one"
    dry "Secret $1/$2 (key token), namespace $1 created if missing"
    return
  fi
  forgejo_api DELETE "/users/$FORGEJO_USER/tokens/$name"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $name of $FORGEJO_USER"
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" DELETE "/users/$FORGEJO_BOT/tokens/$name"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $name"
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" POST "/users/$FORGEJO_BOT/tokens" "$(jq -cn --arg n "$name" \
    '{name: $n, scopes: ["write:organization", "write:repository", "read:user"]}')"
  [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the token $name"
  token="$(jq -r '.sha1' "$FORGEJO_BODY")"
  rm -f "$FORGEJO_BODY"
  secret_write "$1" "$2" "token=$token"
  echo "Secret $1/$2: the access token $name of $FORGEJO_BOT"
}

# forgejo_protect_branch OWNER REPO BRANCH: branch protection on BRANCH of the output
# repository: the push whitelist is FORGEJO_BOT alone (the CI's token, its account:
# forgejo_bot first, Forgejo keeps on the whitelist the users that write to the
# repository only), no force push, no deletion. Nobody else pushes there, the admin
# and the console included: a writer of the output deploys anything, past every
# check of the compile.
forgejo_protect_branch() {
  local body
  if $DRY_RUN; then dry "branch protection on $1/$2 $3: push whitelist $FORGEJO_BOT, no force push"; return; fi
  body="$(jq -cn --arg b "$3" --arg u "$FORGEJO_BOT" '{branch_name: $b, rule_name: $b,
    enable_push: true, enable_push_whitelist: true, push_whitelist_usernames: [$u],
    push_whitelist_teams: [], push_whitelist_deploy_keys: false, enable_force_push: false,
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
  [[ "$(jq -c --arg u "$FORGEJO_BOT" '[.enable_push, .enable_push_whitelist, .push_whitelist_usernames == [$u]]' "$FORGEJO_BODY")" == '[true,true,true]' ]] \
    || die "branch protection on $1/$2 $3: the push whitelist is not $FORGEJO_BOT alone ($(jq -c '.push_whitelist_usernames' "$FORGEJO_BODY"))"
}

# forgejo_engine_secrets OWNER [NAMESPACE SECRET]...: a read-only access token of
# FORGEJO_BOT for the engines (Argo CD, Flux) to pull private repositories, written
# to each NAMESPACE/SECRET (keys username, password). The previous token of that
# name is deleted.
forgejo_engine_secrets() {
  local owner="$1" name=okdp-engine-reader token; shift
  if $DRY_RUN; then
    while [[ $# -ge 2 ]]; do dry "Secret $1/$2: read token of $FORGEJO_BOT"; shift 2; done
    return
  fi
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" DELETE "/users/$FORGEJO_BOT/tokens/$name"
  [[ "$FORGEJO_STATUS" == 204 || "$FORGEJO_STATUS" == 404 ]] || forgejo_fail "cannot delete the token $name"
  forgejo_api_as "$FORGEJO_BOT" "$FORGEJO_BOT_PASSWORD" POST "/users/$FORGEJO_BOT/tokens" "$(jq -cn --arg n "$name" \
    '{name: $n, scopes: ["read:repository"]}')"
  [[ "$FORGEJO_STATUS" == 201 ]] || forgejo_fail "cannot create the token $name"
  token="$(jq -r '.sha1' "$FORGEJO_BODY")"
  rm -f "$FORGEJO_BODY"
  while [[ $# -ge 2 ]]; do
    secret_write "$1" "$2" "username=$FORGEJO_BOT" "password=$token"
    echo "Secret $1/$2: the access token $name of $FORGEJO_BOT (read:repository)"
    shift 2
  done
}
