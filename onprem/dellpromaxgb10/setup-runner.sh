#!/usr/bin/env bash
# Stawia self-hosted runner organizacji Meritum-HackNation2026 na dellpromaxgb10.
# Uruchamiaj lokalnie (potrzebny gh z zakresem admin:org i ssh do hosta).
# Skrypt jest idempotentny: pomija kroki, które już są zrobione.
# Użycie: ./setup-runner.sh [host-ssh]
set -euo pipefail

HOST=${1:-dellpromaxgb10}
ORG=Meritum-HackNation2026
NAME=dellpromaxgb10
LABELS=dellpromaxgb10,arm64,gpu,backend
RUNNER_USER=meritum-runner
DIR=/opt/meritum-runner

RELEASE=$(gh api repos/actions/runner/releases/latest)
VERSION=$(jq -r '.tag_name | ltrimstr("v")' <<<"$RELEASE")
SHA=$(jq -r '.body' <<<"$RELEASE" | sed -n 's/.*<!-- BEGIN SHA linux-arm64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-arm64 -->.*/\1/p')
[[ -n $SHA ]] || { echo "Brak sumy SHA256 dla linux-arm64 w release v$VERSION" >&2; exit 1; }
TOKEN=$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" --jq .token)

# Token idzie przez stdin, nie przez argumenty ssh.
{
  printf 'ORG=%q NAME=%q LABELS=%q RUNNER_USER=%q DIR=%q VERSION=%q SHA=%q TOKEN=%q\n' \
    "$ORG" "$NAME" "$LABELS" "$RUNNER_USER" "$DIR" "$VERSION" "$SHA" "$TOKEN"
  cat <<'REMOTE'
set -euo pipefail
as_runner() { sudo -u "$RUNNER_USER" -H "$@"; }

id "$RUNNER_USER" &>/dev/null || useradd --system --create-home --shell /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$DIR"
cd "$DIR"

if [[ ! -x config.sh ]]; then
  TGZ=$(mktemp)
  curl -fsSL -o "$TGZ" "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-linux-arm64-$VERSION.tar.gz"
  echo "$SHA  $TGZ" | sha256sum -c -
  chmod a+r "$TGZ"
  as_runner tar xzf "$TGZ" -C "$DIR"
  rm -f "$TGZ"
fi

as_runner docker run --rm hello-world >/dev/null && echo "docker działa dla $RUNNER_USER"

if [[ ! -f .runner ]]; then
  as_runner ./config.sh --unattended --url "https://github.com/$ORG" --token "$TOKEN" \
    --name "$NAME" --labels "$LABELS" --work _work
fi

[[ -f .service ]] || ./svc.sh install "$RUNNER_USER"
./svc.sh start
echo "$(cat .service): $(systemctl is-active "$(cat .service)")"
REMOTE
} | ssh "$HOST" 'sudo bash -s'

gh api "orgs/$ORG/actions/runners" --jq ".runners[] | select(.name == \"$NAME\") | {name,status,labels:[.labels[].name]}"
