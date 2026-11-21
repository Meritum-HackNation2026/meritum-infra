#!/usr/bin/env bash
# Names shared by the platform and the app deploys (meritum-backend, -worker,
# -frontend copy the few they need). Source it, don't run it.
#
#   branch   env  hostname                 web container    api container    worker container
#   main     prd  meritum.gburek.app       meritum-web-prd  meritum-api-prd  meritum-worker-prd
#   develop  dev  meritum-dev.gburek.app   meritum-web-dev  meritum-api-dev  meritum-worker-dev
#
# Platform mocks (meritum-mocks, main only): meritum-<platform>.gburek.app,
# served by meritum-mocks-prd.
#
# Everything created here carries the Docker label meritum.managed=true.
# shellcheck disable=SC2034  # used by the scripts that source this file
M_DOMAIN="${M_DOMAIN:-gburek.app}"
M_STATE="${M_STATE:-$HOME/meritum}"
M_NETWORK="meritum"
M_POSTGRES="meritum-postgres"
M_GATEWAY="meritum-gateway"
# docker0 address: cloudflared (default bridge) reaches it, the LAN does not.
# 18080/18081 are TuttiTrip's, 18090 is ExactDocs'.
M_GATEWAY_BIND="${M_GATEWAY_BIND:-172.17.0.1:18095}"

M_MOCK_PLATFORMS=(x facebook instagram reddit tiktok)

m_log() { printf '[meritum] %s\n' "$*" >&2; }
m_role() { printf 'meritum_%s_%s' "$1" "$2"; }
m_schema() { printf '%s_%s' "$1" "$2"; }
m_host() { if [ "$1" = prd ]; then printf 'meritum.%s' "$M_DOMAIN"; else printf 'meritum-%s.%s' "$1" "$M_DOMAIN"; fi; }
m_mock_host() { if [ "$2" = prd ]; then printf 'meritum-%s.%s' "$1" "$M_DOMAIN"; else printf 'meritum-%s-%s.%s' "$1" "$2" "$M_DOMAIN"; fi; }
