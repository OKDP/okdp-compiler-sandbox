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

# Sourced by lib/forgejo.sh: the CI of the sandbox's Forgejo, the output repository's
# alone. Its workflow (forgejo_output_workflow: a compile of the sources on a schedule,
# the repositories at CI_FORGEJO_URL), the catalogs the CI and the console read
# (forgejo_push_catalogs), its runner (forgejo_register_runner), its token, the only one
# (forgejo_ci_token) and the protection of the output's main, which okdp-ci alone
# pushes (forgejo_protect_branch). The accounts are in lib/forgejo-accounts.sh.

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
