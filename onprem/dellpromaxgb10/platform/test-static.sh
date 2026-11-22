#!/usr/bin/env bash
# Local check, outside PR CI: the static file host (infra#69) behind the real gateway
# config. Starts meritum-static the way setup.sh does (m_static_run) over a temp
# directory, puts a gateway with nginx.conf in front and asks for M_STATIC_HOST.
# Needs bash, curl and docker. VERBOSE=1 prints the response headers of every request.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# setup.sh wires the host into the tunnel and DNS, and starts the container through m_static_run.
# shellcheck disable=SC2016  # the literal calls searched for in setup.sh
{
  grep -qF 'cf_ingress_ensure "$M_STATIC_HOST"' "$here/setup.sh" || fail "setup.sh: no tunnel rule for the static host"
  grep -qF 'cf_dns_ensure "$M_STATIC_HOST"' "$here/setup.sh" || fail "setup.sh: no DNS record for the static host"
  grep -qF 'm_static_run "$M_STATIC" "$M_NETWORK" "$M_STATIC_DIR"' "$here/setup.sh" || fail "setup.sh: does not start $M_STATIC"
}

net="meritum-static-test-$$"; gw="$net-gw"; dir=$(mktemp -d)
cleanup() { docker rm -f "$net" "$gw" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1; rm -rf "$dir"; }
trap cleanup EXIT
mkdir -p "$dir/deck" "$dir/empty"
echo '<!doctype html><title>ok</title>' >"$dir/page.html"
echo '<!doctype html><title>deck</title>' >"$dir/deck/index.html"
head -c 1000 /dev/urandom >"$dir/film.mp4"
echo secret >"$dir/.env"
chmod 600 "$dir/page.html"   # the server runs as the owner, so private modes still serve
for f in a.css a.js a.svg a.png a.jpg a.pdf a.xlsx a.pptx a.json a.txt a.woff2; do echo x >"$dir/$f"; done

docker network create "$net" >/dev/null
m_static_run "$net" "$net" "$dir" "$here/static.nginx.conf" "$(id -u):$(id -g)" --network-alias "$M_STATIC"
docker run -d --name "$gw" --network "$net" -p 127.0.0.1::80 \
  -v "$here/nginx.conf:/etc/nginx/nginx.conf:ro" "$M_NGINX_IMAGE" >/dev/null
base="http://$(docker port "$gw" 80/tcp | head -1)"

# req <curl args>: response headers (no CR) of one request to the static host.
req() {
  local out
  out=$(curl -sS -o /dev/null -D - -H "Host: $M_STATIC_HOST" "$@" | tr -d '\r')
  [ -z "${VERBOSE:-}" ] || printf -- '--- curl %s\n%s\n' "${*: -1}" "$out" >&2
  printf '%s\n' "$out"
}
# expect <status> <header line or ""> <curl args>
expect() {
  local status=$1 line=$2 out; shift 2
  out=$(req "$@")
  grep -q "^HTTP/1.1 $status" <<<"$out" || fail "${*: -1}: want $status, got $(head -1 <<<"$out")"
  [ -z "$line" ] || grep -qix "$line" <<<"$out" || fail "${*: -1}: no header '$line' in: $out"
}
for i in $(seq 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $M_STATIC_HOST" "$base/page.html")" = 200 ] && break
  [ "$i" = 30 ] && fail "static host not up: $(docker logs "$net" 2>&1 | tail -5)"
  sleep 0.5
done

expect 200 'content-type: text/html; charset=utf-8' "$base/page.html"
expect 200 'cache-control: no-cache' "$base/page.html"
expect 200 'x-content-type-options: nosniff' "$base/page.html"
expect 200 'etag: .*' "$base/page.html"
expect 304 'cache-control: no-cache' -H "If-None-Match: $(req "$base/page.html" | grep -i '^etag:' | cut -d' ' -f2)" "$base/page.html"
while read -r file type; do expect 200 "content-type: $type" "$base/$file"; done <<'TYPES'
a.css text/css; charset=utf-8
a.js application/javascript; charset=utf-8
a.svg image/svg+xml; charset=utf-8
a.png image/png
a.jpg image/jpeg
a.pdf application/pdf
a.json application/json; charset=utf-8
a.txt text/plain; charset=utf-8
a.woff2 font/woff2
film.mp4 video/mp4
a.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
a.pptx application/vnd.openxmlformats-officedocument.presentationml.presentation
TYPES
expect 200 'content-disposition: attachment' "$base/a.xlsx"
expect 200 'content-disposition: attachment' "$base/a.pptx"
if req "$base/a.pdf" | grep -qi '^content-disposition'; then fail "pdf must open in the browser"; fi
# Video seeking: byte ranges.
expect 200 'accept-ranges: bytes' "$base/film.mp4"
expect 206 'content-range: bytes 100-199/1000' -H 'Range: bytes=100-199' "$base/film.mp4"
expect 206 'content-length: 100' -H 'Range: bytes=100-199' "$base/film.mp4"
# Nothing beyond the files: no listing, no dotfiles, GET and HEAD only, read-only mount.
expect 404 'x-content-type-options: nosniff' "$base/"
expect 404 '' "$base/empty/"
expect 404 '' "$base/.env"
expect 404 '' "$base/missing.html"
expect 200 '' "$base/deck/"
expect 301 'location: /deck/' "$base/deck"
expect 200 '' -I "$base/page.html"
expect 405 '' -X POST -d x "$base/page.html"
expect 405 '' -X PUT -d x "$base/new.html"
expect 405 '' -X DELETE "$base/page.html"
if docker exec "$net" touch /srv/static/probe 2>/dev/null; then fail "the mount is writable"; fi
# A file dropped into the directory is served at once, without a restart.
echo new >"$dir/new.txt"
expect 200 'content-type: text/plain; charset=utf-8' "$base/new.txt"
echo "static host: ok"
