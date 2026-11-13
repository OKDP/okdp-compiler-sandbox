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

# Sourced by lib/forgejo.sh: the people of the sandbox's Forgejo, who push the sources
# with their own accounts, signed in through Keycloak (forgejo_sign_in), their teams
# from their Keycloak groups (forgejo_people_teams, forgejo_group_team_map). The
# accounts of the roles are in lib/forgejo-accounts.sh.

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
