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
| Pliki przesłane przez obywateli | wolumen Dockera `meritum-files-<env>`, ten sam dla backendu i workera danego środowiska (odpowiednik bucketu z `gcp/storage/`). Deploy aplikacji montuje go pod `MERITUM_FILES_DIR` (`/var/lib/meritum/files`): `-v "$MERITUM_FILES_VOLUME:$MERITUM_FILES_DIR"`, obie zmienne są w plikach env API i workera. Montowanie: backend#50 i worker#52 (deploye jeszcze nie istnieją). Lokalny test: `platform/test-files.sh`. Retencja 30 dni należy tu do adaptera systemu plików (core/021) |
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

## Worker e-mail do moderatorów (Cloudflare)

`cloudflare/email/` to Worker `meritum-email` z wiązaniem `send_email`: backend woła go podpisanym żądaniem, a on wysyła moderatorowi e-mail o sprawie na adres zweryfikowany w Email Routing. Kontrakt żądania, weryfikacja adresów, sekrety i ręczne wdrożenie: [README](cloudflare/email/README.md). Workflow `.github/workflows/email-worker.yml` tylko sprawdza kod (Biome, tsc, `node --test`, knip).

## Runnery GitHub Actions na GCP

`gcp/gh-actions/` stawia 5 maszyn e2-standard-4 (`meritum-gh-runner-1..5`; Ubuntu 24.04, 100 GB, europe-central2-a) i rejestruje je jako self-hosted runnery organizacji `Meritum-HackNation2026` z etykietami `self-hosted, Linux, X64, gcp, meritum`. Runnery należą do grupy runnerów organizacji `meritum-gcp` (dostępna dla wszystkich repozytoriów, zmienna `runner_group`).

```yaml
jobs:
  build:
    runs-on: [self-hosted, meritum]
```

### Uruchomienie

1. `cp .env.example .env` i uzupełnij (albo weź `.env` od właściciela repo; sekrety są też w Settings → Secrets tego repo).
2. `gcloud auth application-default login` oraz `gh auth login` z zakresem `admin:org`.
3. Grupa runnerów musi istnieć (raz na organizację): `gh api -X POST orgs/Meritum-HackNation2026/actions/runner-groups -f name=meritum-gcp -f visibility=all`.
4. `scripts/apply.sh plan`, potem `scripts/apply.sh apply`.

Stan modułu leży w buckecie stanu GCS pod prefiksem `gh-actions` (sekcja „Stan Terraform na GCP”), więc `plan` i `apply` może uruchomić każdy z dostępem do projektu, bez lokalnego `terraform.tfstate`. W kopii, która ma jeszcze lokalny stan, `scripts/apply.sh` zatrzyma się na zmianie backendu: najpierw `terraform -chdir=gcp/gh-actions init -migrate-state`.

Nowa maszyna rejestruje się w grupie `runner_group` przy pierwszym starcie. Runner zarejestrowany wcześniej w innej grupie przenosi się ręcznie: `gh api -X PUT orgs/Meritum-HackNation2026/actions/runner-groups/<id grupy>/runners/<id runnera>` (identyfikatory: `gh api orgs/Meritum-HackNation2026/actions/runner-groups` i `.../actions/runners`).

Skrypt pobiera jednorazowy token rejestracji runnera (ważny 1 h) i przekazuje sekrety z `.env` jako `TF_VAR_*`. Maszyny przy starcie instalują Dockera i runnera, rejestrują się raz i działają jako usługa systemd.

Liczba runnerów: `runner_count`, domyślnie 5 w `gcp/gh-actions/variables.tf`. Wpis `runner_count` w lokalnym `terraform.tfvars` ma pierwszeństwo, więc w kopii sprzed tej zmiany (z `runner_count = 3`) trzeba go usunąć albo poprawić. Po zmianie `scripts/apply.sh plan` musi pokazać tylko dodanie maszyn o kolejnych numerach; zmniejszenie usuwa maszyny o najwyższych numerach, a ich runnery trzeba potem usunąć z ustawień organizacji. Nowe maszyny rejestrują się świeżym tokenem z `scripts/apply.sh apply`, istniejących to nie dotyka.

Dostęp: `ssh -i .ssh/meritum-runner meritum@<ip>` (IP: `terraform -chdir=gcp/gh-actions output runners`). Log instalacji: `/var/log/meritum-runner-setup.log`.

Koszt: ok. 0,135 USD/h za maszynę, czyli ok. 0,67 USD/h za pięć, dopóki działają. Wyłączenie: `scripts/apply.sh destroy` (runnery trzeba potem usunąć z ustawień organizacji).

## Bucket na pliki od obywateli (GCP)

`gcp/storage/` zakłada prywatny bucket Cloud Storage na nagrania i obrazy przesłane do sprawdzenia (ADR-31, retencja 30 dni, `europe-central2`) oraz konta serwisowe `meritum-backend`, `meritum-worker` i `meritum-speech`. Co tworzy, zmienne i apply: [README](gcp/storage/README.md).

## Stan Terraform na GCP

Stan modułów z `gcp/` leży w prywatnym buckecie `agro-prj-sandbox-sd-2332277-meritum-tfstate` (`europe-central2`, wersjonowanie obiektów, publiczny dostęp zablokowany), każdy moduł pod własnym prefiksem: `gh-actions`, `storage`, `state`. Bucket zakłada moduł `gcp/state/` i trzyma w nim także własny stan. Backend GCS blokuje stan na czas `plan` i `apply`, więc dwie osoby nie nadpiszą go sobie nawzajem.

Druga osoba potrzebuje tylko dostępu do projektu: `gcloud auth application-default login`, potem w czystym klonie `terraform -chdir=gcp/<moduł> init` i `plan`. Lokalnych plików `terraform.tfstate` nie ma i nie trzeba ich przekazywać.

Poprzednią wersję stanu przywraca się z historii obiektu: `gcloud storage ls -a gs://agro-prj-sandbox-sd-2332277-meritum-tfstate/<prefiks>/default.tfstate`, potem `gcloud storage cp` wybranej generacji na `default.tfstate`.

Bloki `backend "gcs"` nie przyjmują zmiennych, więc nazwa bucketu jest wpisana w każdy moduł; `project_id` w `gcp/state` musi być `agro-prj-sandbox-sd-2332277` (pilnuje tego test modułu).

CI (`.github/workflows/terraform.yml`) uruchamia dla każdego modułu w `gcp/` `terraform fmt -check`, `terraform validate` i `terraform test` (plan na atrapie dostawcy, bez poświadczeń, `init -backend=false`).

Pierwsze założenie bucketu (raz na projekt, bucket jeszcze nie istnieje, więc moduł startuje ze stanem lokalnym):

```bash
cp gcp/state/terraform.tfvars.example gcp/state/terraform.tfvars   # project_id
printf 'terraform {\n  backend "local" {}\n}\n' >gcp/state/backend_override.tf   # ignorowany przez git
terraform -chdir=gcp/state init
terraform -chdir=gcp/state plan -out=state.tfplan
terraform -chdir=gcp/state apply state.tfplan
rm gcp/state/backend_override.tf
terraform -chdir=gcp/state init -migrate-state   # przenosi stan bucketu do niego samego
```

Przeniesienie lokalnego stanu modułu do bucketu (zrobione raz dla `gh-actions` i `storage`): `terraform -chdir=gcp/<moduł> init -migrate-state`, potem `plan` musi pokazać `No changes`. Dopiero wtedy lokalny `terraform.tfstate` można usunąć.
