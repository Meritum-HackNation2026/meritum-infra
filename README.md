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
| Bazy, schematy i role | baza `meritum`: schematy `app_dev` i `app_prd` (właściciel `meritum_worker_<env>`, który robi migracje; `meritum_api_<env>` czyta i zapisuje bez prawa do DDL), `mocks_prd` (`meritum_mocks_prd`, mocki wdrażamy wyłącznie z `main`) a wspólny `corpus` dochodzi w infra#4 (tego skryptu go nie zakłada). Tabele DBOS w osobnej bazie na środowisko: `meritum_dbos_dev`, `meritum_dbos_prd` (właściciel rola workera, API ma `CONNECT`, a dostęp do schematu `dbos` dostaje przez `dbos migrate -r` w deployu workera). Role jednego środowiska nie mają dostępu do schematu ani bazy DBOS drugiego; wszyscy czytają `public` (pgvector, pg_trgm, `public.polish`). Układ: `platform/db.sh` |
| Pliki env | `~meritum-runner/meritum/envs/{api,worker}-{dev,prd}.env` i `mocks-prd.env` (600), czytane przez deploye aplikacji: `MERITUM_DATABASE_URL` (baza `meritum`, `search_path` `app_<env>, public` w parametrze `options`), `MERITUM_DBOS_URL` (baza `meritum_dbos_<env>`), `MERITUM_DBOS_SCHEMA=dbos`, u workera `MERITUM_API_ROLE`; hasła w `~/meritum/db.env`, wspólne sekrety aplikacji opcjonalnie w `~/meritum/app.env` |
| Gateway | `meritum-gateway` (nginx) na `172.17.0.1:18095`: `meritum.gburek.app` → `meritum-web-prd`, `meritum-dev.gburek.app` → `meritum-web-dev`, `meritum-<platforma>.gburek.app` → `meritum-mocks-prd` (platformy: x, facebook, instagram, reddit, tiktok) |
| Cloudflare | reguły tunelu i rekordy DNS dla wszystkich 7 adresów (sekret repo `CLOUDFLARE_API_TOKEN`: token konta `meritum-platform-deploy`, Tunnel Edit i DNS Edit na gburek.app, wygasa 2026-12-21; zmienne repo `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ZONE_ID`) |

Porty 18080 i 18081 należą do TuttiTrip, 18090 do ExactDocs. Skrypt dotyka tylko zasobów z prefiksem `meritum` i hostów `meritum(-*).gburek.app`.

### Układ bazy: `app_<env>` i `meritum_dbos_<env>`

Ten sam układ ma `docker-compose.yml` w monorepo (monorepo#1) i GCP (infra#5): jedna instancja PostgreSQL, w bazie `meritum` schematy `app_dev` i `app_prd` (oraz `corpus` z infra#4), a tabele DBOS w bazach `meritum_dbos_dev` i `meritum_dbos_prd`. API i worker tego samego środowiska czytają jeden schemat aplikacji, tabele zakłada worker (migracje w jego deployu). Ponowne uruchomienie `setup.sh` niczego nie usuwa, a hasła ról zostają w `~/meritum/db.env`.

Test lokalny, poza CI pull requestów: `onprem/dellpromaxgb10/platform/test-db.sh` startuje obraz `meritum-postgres`, stosuje układ dwa razy i sprawdza schematy, bazy i uprawnienia ról.

Przejście ze starego układu (schematy `api_<env>` i `worker_<env>`, tabele DBOS w `worker_<env>`). Są tam tylko dane testowe, więc kolejność jest prosta:

1. Kopia na serwerze: `docker exec meritum-postgres pg_dumpall -U meritum | gzip >~/meritum/backups/pg_dumpall-przed-app-schema.sql.gz`.
2. Workflow Platform (scalenie tej zmiany na `main` albo ręcznie) tworzy `app_dev`, `app_prd`, bazy DBOS i nowe pliki env. Stare schematy zostają.
3. Wdrożenie na nowym układzie (worker#35, core#23), w każdym środowisku najpierw worker, potem API. Worker robi `dbos migrate` w `meritum_dbos_<env>` i migracje w `app_<env>`. Pliki env API wskazują nową bazę DBOS od razu po kroku 2, więc API wdrożone przed workerem nie ma jeszcze schematu `dbos` i nie zleci zadań.
4. Po udanym wdrożeniu usunięcie starych schematów, ręcznie:
   `docker exec meritum-postgres psql -U meritum -d meritum -c 'DROP SCHEMA api_dev, api_prd, worker_dev, worker_prd CASCADE'`.
   Stary `search_path` ustawiony na całą rolę przestaje działać (ustawienie `IN DATABASE meritum` ma pierwszeństwo), ale można go wyczyścić: `ALTER ROLE meritum_api_dev RESET search_path` i tak samo dla pozostałych trzech ról.

### Obraz PostgreSQL `meritum-postgres`

`platform/postgres/Dockerfile`: `pgvector/pgvector:0.8.7-pg18-trixie` z pakietem `hunspell-pl`. Przy pierwszym starcie (pusty wolumen) skrypty init tworzą w bazie `POSTGRES_DB` rozszerzenia `vector` i `pg_trgm` oraz konfigurację `public.polish` (słownik Hunspell z polskimi stop words, potem `simple`), więc `to_tsvector('public.polish', 'Tuska')` i `'Tusk'` dają ten sam leksem.

- Rejestr: `ghcr.io/meritum-hacknation2026/meritum-postgres:<pgvector>-<pg>-<commit>`, np. `0.8.7-pg18-1a2b3c4`, dla `linux/amd64` i `linux/arm64`. Publikuje go workflow `.github/workflows/postgres-image.yml` po zmianie obrazu na `main` (albo ręcznie). Tagu `latest` nie ma: docker compose i GCP przypinają konkretny tag. Pakiet jest prywatny jak repo, więc przed `docker pull` trzeba `docker login ghcr.io` (token z `read:packages`).
- Serwer zespołu buduje ten sam `Dockerfile` lokalnie w `setup.sh` (tag z hasza plików), bez logowania do rejestru.
- Test lokalny, poza CI pull requestów: `onprem/dellpromaxgb10/platform/postgres/test.sh` buduje obraz (albo bierze podany jako argument), startuje go i sprawdza `public.polish` oraz rozszerzenia.
- Licencja słownika: `hunspell-pl` (Debian, źródło `libreoffice-dictionaries`) ma dla `dictionaries/pl_PL/*` licencję do wyboru „GPL or LGPL or MPL or Apache-2.0 or CC-SA-1.0” (autor Marek Futrega, `/usr/share/doc/hunspell-pl/copyright` w obrazie). Korzystamy z niej na warunkach Apache-2.0.

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
