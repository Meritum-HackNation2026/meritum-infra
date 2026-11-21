# Runner na dellpromaxgb10

Self-hosted runner GitHub Actions organizacji `Meritum-HackNation2026` na naszym serwerze Dell Pro Max GB10 (NVIDIA Grace, ARM64, Ubuntu 24.04, 20 rdzeni, 120 GB RAM, Docker). Tu będą wdrażane backend (FastAPI), workery DBOS i PostgreSQL z pgvector, przez workflowy uruchamiane na tym runnerze.

| | |
|---|---|
| Nazwa runnera | `dellpromaxgb10` |
| Etykiety | `self-hosted, Linux, ARM64, dellpromaxgb10, gpu, backend` |
| Katalog | `/opt/meritum-runner` (katalog roboczy jobów: `_work`) |
| Użytkownik | `meritum-runner` (w grupie `docker`) |
| Usługa systemd | `actions.runner.Meritum-HackNation2026.dellpromaxgb10.service` |

## Użycie w workflow

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, dellpromaxgb10]
```

Joby działają bezpośrednio na hoście, nie w kontenerze. Obrazy Dockera muszą być zbudowane dla `linux/arm64`.

## Instalacja

```bash
./setup-runner.sh            # domyślnie host ssh "dellpromaxgb10"
```

Uruchamiasz lokalnie. Potrzebny jest `gh` zalogowany z zakresem `admin:org`, `jq` i dostęp `ssh dellpromaxgb10` z sudo bez hasła. Skrypt pobiera token rejestracji z `gh api` w chwili uruchomienia i przekazuje go przez stdin ssh. Zakłada użytkownika, ściąga najnowszy `actions/runner` dla linux-arm64 (ze sprawdzeniem SHA256), sprawdza Dockera (`hello-world`), rejestruje runner i stawia usługę. Kroki już wykonane pomija, więc można go puszczać ponownie.

## Obsługa

```bash
# stan
gh api orgs/Meritum-HackNation2026/actions/runners --jq '.runners[] | {name,status,labels:[.labels[].name]}'
ssh dellpromaxgb10 'systemctl status actions.runner.Meritum-HackNation2026.dellpromaxgb10'
ssh dellpromaxgb10 'journalctl -u actions.runner.Meritum-HackNation2026.dellpromaxgb10 -f'

# restart
ssh dellpromaxgb10 'cd /opt/meritum-runner && sudo ./svc.sh stop && sudo ./svc.sh start'

# usunięcie
TOKEN=$(gh api -X POST orgs/Meritum-HackNation2026/actions/runners/remove-token --jq .token)
ssh dellpromaxgb10 "cd /opt/meritum-runner && sudo ./svc.sh uninstall && sudo -u meritum-runner ./config.sh remove --token $TOKEN"
```

## Inne runnery na tym hoście

Na tej maszynie działa też runner innego projektu (`actions.runner.SirCypkowskyy-ExactDocs.exactdocs-deploy`, katalog w `/home/cyprian`). Nie należy do nas: nie zatrzymuj go, nie zmieniaj i nie usuwaj. Oba runnery dzielą CPU, RAM, dysk i demona Dockera, więc nie czyść globalnie obrazów ani wolumenów (`docker system prune` itp.) i nie zajmuj portów, których mogą używać jego kontenery.
