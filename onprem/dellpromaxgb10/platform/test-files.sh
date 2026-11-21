#!/usr/bin/env bash
# Local check, outside PR CI: setup.sh gives the api and worker of one env the same
# files volume and the two envs different ones, writable by the app user (uid 999 in
# both images). Needs bash and docker.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
dev=$(m_files_env dev); prd=$(m_files_env prd)
grep -qx 'MERITUM_FILES_VOLUME=meritum-files-dev' <<<"$dev" || fail "dev volume: $dev"
grep -qx "MERITUM_FILES_DIR=$M_FILES_DIR" <<<"$dev" || fail "dev dir: $dev"
[ "$dev" != "$prd" ] || fail "dev and prd share a volume"
# Both env files of an env take their lines from m_files_env.
[ "$(grep -cF "m_files_env \"\$env\"" "$here/setup.sh")" = 2 ] || fail "setup.sh: api and worker env files must both call m_files_env"
# shellcheck disable=SC2016  # the literal call searched for in setup.sh
grep -qF 'm_files_own "$(m_files_volume "$env")"' "$here/setup.sh" || fail "setup.sh: files volumes must be handed to the app user"
# A fresh volume belongs to root; m_files_own hands it to the app user.
vol="meritum-files-test-$$"
docker volume create "$vol" >/dev/null
trap 'docker volume rm -f "$vol" >/dev/null' EXIT
m_files_own "$vol" alpine:3.20
docker run --rm --user "$M_APP_UID:$M_APP_UID" -v "$vol:$M_FILES_DIR" alpine:3.20 touch "$M_FILES_DIR/probe" \
  || fail "the app user cannot write to the files volume"
echo "files volume: ok"
