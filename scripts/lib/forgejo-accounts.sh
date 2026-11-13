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

# Sourced by lib/forgejo.sh: the accounts and the teams of the sandbox's Forgejo, none
# an admin, each reaching its repositories through teams of the organization only:
# forgejo_user, forgejo_token, forgejo_team, forgejo_accounts (okdp-ci, okdp-reader,
# okdp-console), the cleanup of an older sandbox's single account, and the Secrets the
# console and the engines read their tokens from. The CI's own token and workflow are in
# lib/forgejo-ci.sh, the people in lib/forgejo-people.sh.

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
