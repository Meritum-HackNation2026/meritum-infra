# Meritum infra

Infrastruktura projektu Meritum (HackNation 2026).

## Runnery GitHub Actions na GCP

`gcp/gh-actions/` stawia 3 maszyny e2-standard-4 (Ubuntu 24.04, 100 GB, europe-central2-a) i rejestruje je jako self-hosted runnery organizacji `Meritum-HackNation2026` z etykietami `self-hosted, Linux, X64, gcp, meritum`.

```yaml
jobs:
  build:
    runs-on: [self-hosted, meritum]
```

### Uruchomienie

1. `cp .env.example .env` i uzupełnij (albo weź `.env` od właściciela repo; sekrety są też w Settings → Secrets tego repo).
2. `gcloud auth application-default login` oraz `gh auth login` z zakresem `admin:org`.
3. `scripts/apply.sh plan`, potem `scripts/apply.sh apply`.

Skrypt pobiera jednorazowy token rejestracji runnera (ważny 1 h) i przekazuje sekrety z `.env` jako `TF_VAR_*`. Maszyny przy starcie instalują Dockera i runnera, rejestrują się raz i działają jako usługa systemd.

Dostęp: `ssh -i .ssh/meritum-runner meritum@<ip>` (IP: `terraform -chdir=gcp/gh-actions output runners`). Log instalacji: `/var/log/meritum-runner-setup.log`.

Koszt: ok. 0,40 USD/h za trzy maszyny, dopóki działają. Wyłączenie: `scripts/apply.sh destroy` (runnery trzeba potem usunąć z ustawień organizacji).
