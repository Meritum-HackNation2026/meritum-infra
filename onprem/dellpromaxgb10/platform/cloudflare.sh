#!/usr/bin/env bash
# Cloudflare helpers (from TuttiTrip's deploy/cloudflare.sh): tunnel ingress of
# the remotely managed tunnel on dellpromaxgb10, and DNS. Source after lib.sh.
# Needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TUNNEL_ID and
# (for DNS) CLOUDFLARE_ZONE_ID.
#
# The tunnel is shared with other projects. Only hostnames matching CF_HOST_RE
# are ever added; rules go before any wildcard and the full config is backed up
# before every write. cloudflared picks changes up live.

CF_API="https://api.cloudflare.com/client/v4"
CF_MARK="managed-by=meritum-platform"
# Our hostnames: meritum.<domain> and meritum-<name>.<domain>.
CF_HOST_RE="^meritum(-[a-z0-9-]+)?\\.${M_DOMAIN//./\\.}$"

cf_api() {
  local method=$1 url=$2 body=${3:-}
  local args=(-sS -X "$method" -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN:?}" \
    -H "Content-Type: application/json" "$CF_API$url")
  [ -n "$body" ] && args+=(--data "$body")
  curl "${args[@]}"
}

cf_config_url() { printf '/accounts/%s/cfd_tunnel/%s/configurations' "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_TUNNEL_ID:?}"; }

# Print the tunnel config JSON (.result.config).
cf_get_config() {
  local resp
  resp=$(cf_api GET "$(cf_config_url)")
  if [ "$(jq -r '.success' <<<"$resp")" != true ]; then
    m_log "cannot read tunnel config: $(jq -c '.errors' <<<"$resp")"; return 1
  fi
  jq '.result.config' <<<"$resp"
}

# cf_put_config <old-json> <new-json>: back up old, write new if different.
cf_put_config() {
  local old=$1 new=$2 backup resp
  if [ "$(jq -S . <<<"$old")" = "$(jq -S . <<<"$new")" ]; then m_log "tunnel ingress unchanged"; return 0; fi
  mkdir -p "$M_STATE/backups"
  backup="$M_STATE/backups/tunnel-config-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  printf '%s\n' "$old" >"$backup"
  # shellcheck disable=SC2012  # our own timestamped file names
  ls -1t "$M_STATE"/backups/tunnel-config-*.json | tail -n +51 | xargs -r rm -f  # keep 50
  resp=$(cf_api PUT "$(cf_config_url)" "$(jq -c '{config: .}' <<<"$new")")
  if [ "$(jq -r '.success' <<<"$resp")" != true ]; then
    m_log "tunnel config update failed: $(jq -c '.errors' <<<"$resp") (backup: $backup)"; return 1
  fi
  m_log "tunnel ingress updated (previous config: $backup)"
}

# cf_ingress_ensure <hostname> <service>: our rule goes first, before wildcards.
cf_ingress_ensure() {
  local host=$1 service=$2 old new
  [[ $host =~ $CF_HOST_RE ]] \
    || { m_log "refusing foreign hostname $host"; return 1; }
  old=$(cf_get_config) || return 1
  # A rule already pointing at the service stays where it is (no rewrite, no reorder).
  new=$(jq --arg h "$host" --arg s "$service" '
    if any(.ingress[]; .hostname == $h and .service == $s) then .
    else .ingress = ([{hostname: $h, service: $s}] + [.ingress[] | select(.hostname != $h)]) end' <<<"$old")
  cf_put_config "$old" "$new"
}



# DNS is best-effort: a proxied wildcard *.<domain> may already cover us, and
# the token may lack Zone:DNS:Edit. Failures are logged, never fatal.
cf_dns_ensure() {
  local host=$1 resp
  [ -n "${CLOUDFLARE_ZONE_ID:-}" ] || { m_log "CLOUDFLARE_ZONE_ID unset, skipping DNS"; return 0; }
  resp=$(cf_api GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$host")
  if [ "$(jq -r '.success' <<<"$resp")" != true ]; then
    m_log "DNS not managed (token lacks DNS access?): $(jq -c '.errors' <<<"$resp"); relying on wildcard"; return 0
  fi
  if [ "$(jq '.result | length' <<<"$resp")" != 0 ]; then m_log "DNS record for $host exists"; return 0; fi
  resp=$(cf_api POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$(jq -nc --arg n "$host" \
    --arg c "$CLOUDFLARE_TUNNEL_ID.cfargotunnel.com" --arg m "$CF_MARK" \
    '{type: "CNAME", name: $n, content: $c, proxied: true, comment: $m}')")
  m_log "DNS create $host: success=$(jq -r '.success' <<<"$resp") $(jq -c '.errors' <<<"$resp")"
}

