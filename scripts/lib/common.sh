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

# Sourced by lib/topology.sh and scripts/bootstrap.sh: the helpers the scripts share.

# DCR_NAMESPACES: the non-privileged project namespaces whose services register their
# OAuth clients by DCR (platform.yaml, oidc.clientProvisioning: dcr, authMethod:
# initialAccessToken), space-separated: scripts/bootstrap.sh has the bootstrap mint an
# initial access token for each (sandbox-charts' bootstrap/openbao/init.sh, written
# to <namespace>/keycloak/dcr-token), and scripts/check.sh warns of one whose secrets
# instance does not read it into Secret okdp-dcr-token. One list for both.
DCR_NAMESPACES="${DCR_NAMESPACES:-demo}"

# random_hex BYTES: BYTES random bytes, in hexadecimal.
random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# secret_value NAMESPACE SECRET KEY: the value of KEY of a Secret of the current
# context; fails when the Secret or the key is missing.
secret_value() {
  local v
  v="$(kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null)" && [[ -n "$v" ]] || return 1
  printf '%s' "$v" | base64 -d
}
