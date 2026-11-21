# Meritum infra

Infrastruktura projektu Meritum (HackNation 2026).

## Runner on-prem na dellpromaxgb10

`onprem/dellpromaxgb10/` opisuje runner `dellpromaxgb10` (ARM64, etykiety `dellpromaxgb10, gpu, backend`) na naszym serwerze Dell Pro Max GB10. Na nim wdrażamy backend, workery DBOS i PostgreSQL z pgvector. Host dzieli z runnerem innego projektu. Instalacja: `onprem/dellpromaxgb10/setup-runner.sh`, szczegóły w [README](onprem/dellpromaxgb10/README.md).

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, dellpromaxgb10]
```

## Platforma aplikacji na dellpromaxgb10

`onprem/dellpromaxgb10/platform/setup.sh` stawia wspólną część dla backendu, workera i frontendu. Uruchamia go workflow `.github/workflows/platform.yml` (po zmianie tych plików na `main` albo ręcznie: Actions → Platform → Run workflow). Skrypt jest idempotentny.

| Element | Szczegóły |
| --- | --- |
| Sieć Dockera | `meritum` |
| PostgreSQL | kontener `meritum-postgres` z obrazu `platform/postgres/` (PG 18, pgvector, pg_trgm, polski słownik Hunspell), baza `meritum`, wolumen `meritum-postgres-data`. Wyszukiwanie pełnotekstowe po polsku: konfiguracja `public.polish`, np. `to_tsvector('public.polish', tekst) @@ websearch_to_tsquery('public.polish', pytanie)`. Zmiana obrazu podmienia kontener na tym samym wolumenie, po zrzucie `pg_dumpall` do `~/meritum/backups/` |
| Role i schematy | `meritum_<app>_<env>` → `<app>_<env>` dla `api` i `worker` w `dev` i `prd` oraz `mocks` tylko w `prd` (mocki wdrażamy wyłącznie z `main`); każda rola ma tylko swój schemat (plus odczyt `public`, gdzie są pgvector i pg_trgm) |
| Pliki env | `~meritum-runner/meritum/envs/{api,worker}-{dev,prd}.env` i `mocks-prd.env` (600), czytane przez deploye aplikacji; hasła w `~/meritum/db.env`, wspólne sekrety aplikacji opcjonalnie w `~/meritum/app.env` |
| Gateway | `meritum-gateway` (nginx) na `172.17.0.1:18095`: `meritum.gburek.app` → `meritum-web-prd`, `meritum-dev.gburek.app` → `meritum-web-dev`, `meritum-<platforma>.gburek.app` → `meritum-mocks-prd` (platformy: x, facebook, instagram, reddit, tiktok) |
| Cloudflare | reguły tunelu i rekordy DNS dla wszystkich 7 adresów (sekret repo `CLOUDFLARE_API_TOKEN`: token konta `meritum-platform-deploy`, Tunnel Edit i DNS Edit na gburek.app, wygasa 2026-12-21; zmienne repo `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ZONE_ID`) |

Porty 18080 i 18081 należą do TuttiTrip, 18090 do ExactDocs. Skrypt dotyka tylko zasobów z prefiksem `meritum` i hostów `meritum(-*).gburek.app`.

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
