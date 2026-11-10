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

# Moves the pins of the catalogs: sets the ref of catalogs.yaml of each catalog named
# (every catalog without NAME) to a commit, its full hash, the one given (NAME=COMMIT)
# or the HEAD of the checkout NAME next to this repository (NAME, or no argument),
# its uncommitted changes warned of (they are not in the commit). The sandbox reads
# each catalog at that commit (scripts/lib/topology.sh), scripts/bootstrap.sh runs
# sandbox-charts' bootstrap/ of it. Edits catalogs.yaml only: review and commit it,
# the commits pinned pushed to the catalogs' repositories first (GitHub, which the CI
# and the bootstrap fetch them from by their hash).
#
#   --root DIR   the layout whose catalogs.yaml is edited (default: gitops/ of this
#                repository)
#
# Usage: bump-catalogs.sh [--root DIR] [NAME[=COMMIT]]...
# Requires bash >= 4, yq v4, git.

set -euo pipefail

PROG=bump-catalogs
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../gitops" && pwd)"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '18,31p' "$0"; exit 0 ;;
    -*) echo "bump-catalogs: unknown argument: $1" >&2; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# shellcheck source=lib/topology.sh
source "$SCRIPTS/lib/topology.sh"

[[ -f "$CATALOG_FILE" ]] || die "no $CATALOG_FILE"
if [[ ${#ARGS[@]} -eq 0 ]]; then
  mapfile -t ARGS < <(catalog_list | cut -f1)
fi

for a in "${ARGS[@]}"; do
  name="${a%%=*}"
  catalog_name_check "$name"
  old="$(catalog_ref "$name")"
  [[ -n "$old" ]] || die "catalogs.yaml names no catalog $name"
  if [[ "$a" == *=* ]]; then
    commit="${a#*=}"
    catalog_ref_is_commit "$commit" || die "$a: not a full commit hash (40 lowercase hexadecimal digits)"
  else
    sib="$SANDBOX_TOP/../$name"
    [[ -d "$sib" ]] || die "$name: no checkout $sib next to this repository (give NAME=COMMIT)"
    commit="$(git -C "$sib" rev-parse --verify 'HEAD^{commit}')" || die "$name: $sib is not a Git checkout"
    if [[ -n "$(git -C "$sib" status --porcelain --untracked-files=no)" ]]; then
      echo "$PROG: warning: $sib has uncommitted changes, not in the commit ${commit:0:12}" >&2
    fi
  fi
  if [[ "$old" == "$commit" ]]; then
    echo "$name: $commit (unchanged)"
    continue
  fi
  # The ref line of the entry, in place (yq -i would restyle the rest of the file):
  # "  - name: NAME" then its "    ref: ...", its comment kept.
  tmp="$(mktemp)"
  awk -v name="$name" -v commit="$commit" '
    /^[^ #]/ { section = $0 ~ /^repositories:/ }
    section && /^  - / { current = ""; if (match($0, /name: *[^ ,}]+/)) { current = substr($0, RSTART, RLENGTH); sub(/name: */, "", current) } }
    section && current == name && /^ +ref: *[^ #]+/ { sub(/ref: *[^ #]+/, "ref: " commit) }
    { print }' "$CATALOG_FILE" >"$tmp"
  cat "$tmp" >"$CATALOG_FILE"; rm -f "$tmp"
  [[ "$(catalog_ref "$name")" == "$commit" ]] \
    || die "$name: no line 'ref: ...' of its entry in $CATALOG_FILE (its ref is '$(catalog_ref "$name")'): set it by hand to $commit"
  echo "$name: $old -> $commit"
done
