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
| Bazy, schematy i role | baza `meritum`: schematy `app_dev` i `app_prd` (właściciel `meritum_worker_<env>`, który robi migracje; `meritum_api_<env>` czyta i zapisuje bez prawa do DDL), `mocks_prd` (`meritum_mocks_prd`, mocki wdrażamy wyłącznie z `main`), oraz wspólny dla obu środowisk `corpus` (właściciel `meritum_worker_prd`, jedyny z prawem zapisu; API i worker `dev` oraz API `prd` tylko czytają, mocki nie mają dostępu). Tabele DBOS w osobnej bazie na środowisko: `meritum_dbos_dev`, `meritum_dbos_prd` (właściciel rola workera, API ma `CONNECT`, a dostęp do schematu `dbos` dostaje przez `dbos migrate -r` w deployu workera). Role jednego środowiska nie mają dostępu do schematu ani bazy DBOS drugiego; wszyscy czytają `public` (pgvector, pg_trgm, `public.polish`). Układ: `platform/db.sh` |
| Pliki przesłane przez obywateli | wolumen Dockera `meritum-files-<env>`, ten sam dla backendu i workera danego środowiska (odpowiednik bucketu z `gcp/storage/`). Deploy aplikacji montuje go pod `MERITUM_FILES_DIR` (`/var/lib/meritum/files`): `-v "$MERITUM_FILES_VOLUME:$MERITUM_FILES_DIR"`, obie zmienne są w plikach env API i workera. Worker buduje magazyn tylko z `MERITUM_BLOB_*` (`BlobSettings` z meritum-core), więc te same pliki dostają też `MERITUM_BLOB_PROVIDER=filesystem` i `MERITUM_BLOB_DIRECTORY` (ten sam katalog); backend i tak bierze najpierw `MERITUM_FILES_DIR`. Obrazy obu aplikacji działają jako `nonroot` (uid 999), a świeży wolumen należy do roota, więc `setup.sh` przy każdym uruchomieniu oddaje go temu użytkownikowi (`m_files_own` z `platform/lib.sh`); bez tego zapis nagrania kończy się 503 `file storage unavailable`. Montowanie: `deploy/` w meritum-backend i meritum-worker. Klucz `MERITUM_BLOB_*` w `~/meritum/app.env` nadpisałby te linie i znów rozdzielił magazyny backendu i workera. Lokalny test: `platform/test-files.sh`. Retencja 30 dni należy tu do adaptera systemu plików (core/021) |
| Pliki env | `~meritum-runner/meritum/envs/{api,worker}-{dev,prd}.env` i `mocks-prd.env` (600), czytane przez deploye aplikacji: `MERITUM_DATABASE_URL` (baza `meritum`, `search_path` `app_<env>, public` w parametrze `options`), `MERITUM_DBOS_URL` (baza `meritum_dbos_<env>`), `MERITUM_DBOS_SCHEMA=dbos`, `MERITUM_DATABASE_PROVIDER=postgres` (repozytoria aplikacji z meritum-core w PostgreSQL zamiast w pamięci), u workera `MERITUM_API_ROLE`, a w `worker-dev.env` także `MERITUM_LLM_STUB_FIXTURES=/app/features/fixtures/llm_stub_answer.json` (zapas na powrót do stubu, który bez fikstur kończy każde sprawdzenie stanem `technical_failure`). Worker dev woła prawdziwy model (D9, core#97): `MERITUM_LLM_PROVIDER=openrouter`, `MERITUM_LLM_MODEL=anthropic/claude-haiku-5.5`, `MERITUM_LLM_REASONING=high`; klucz `OPENROUTER_API_KEY` dokłada deploy meritum-worker z sekretu repozytorium, nigdy plik env. `worker-prd.env` ma `MERITUM_LLM_PROVIDER=stub`, dopóki deploy z `main` nie przekazuje klucza (domyślny dostawca w core to teraz `openrouter`). API nie buduje `LlmPort` i nie dostaje tych zmiennych. Korpus (infra#57): oba pliki workera mają `MERITUM_CORPUS_PROVIDER=postgres` i `MERITUM_CORPUS_DATABASE_URL` z rolą workera swojego środowiska i `search_path` `corpus, public`. Pisze tylko `meritum_worker_prd` (właściciel schematu, migracje `corpus` z `main` workera), więc tylko `worker-prd.env` ma `MERITUM_CORPUS_INGEST=enabled` (harmonogramy `corpus_ingest` i `corpus_snapshot`); rola dev ma w `corpus` wyłącznie odczyt. Z poświadczeniami GCP oba workery dostają embeddingi w UE (decyzja D2): `MERITUM_EMBEDDINGS_PROVIDER=vertex`, `MERITUM_EMBEDDINGS_MODEL=gemini-embedding-001`, `MERITUM_EMBEDDINGS_REGION=europe-central2` i `MERITUM_EMBEDDINGS_PROJECT` (`m_embeddings_env`), bo ingest i wyszukiwanie muszą używać jednego modelu. Worker przeszukuje jedną przypiętą migawkę (`search_corpus`, bez automatycznej najnowszej): `MERITUM_CORPUS_VERSION` ze zmiennych repo `MERITUM_CORPUS_VERSION_DEV` i `MERITUM_CORPUS_VERSION_PRD` (`m_corpus_version_env`); bez zmiennej linii nie ma i krok jest pomijany. Identyfikator migawki: `SELECT DISTINCT corpus_version FROM corpus.snapshot_manifest`, potem `gh variable set MERITUM_CORPUS_VERSION_DEV -b <id>`, workflow Platform i deploy workera dev. Gdy `setup.sh` wystawi tożsamość GCP, API i worker dostają też `MERITUM_PII_GATE=sdp`, `MERITUM_PII_PROJECT` (ten sam projekt co `MERITUM_GCP_PROJECT_ID`) i `MERITUM_PII_LOCATION=europe-central2`, żeby bramka Sensitive Data Protection maskowała adresy i numery dokumentów (core#90); bez poświadczeń GCP zostaje bramka pusta z ostrzeżeniem w logu. Z poświadczeniami GCP `worker-dev.env` dostaje też wyszukiwanie na żywo (infra#42): `MERITUM_WEB_SEARCH_PROVIDER=vertex_search`, `MERITUM_WEB_SEARCH_PROJECT` (numer projektu, `MERITUM_GCP_PROJECT_NUMBER`) i `MERITUM_WEB_SEARCH_ENGINE=meritum-live-search` (aplikacja z `gcp/search/`, serving config `default_search`); pozostałe pliki tych zmiennych nie mają. Z poświadczeniami GCP worker (dev i prd) dostaje także `MERITUM_TRANSCRIPTION_PROVIDER=speech_v2` i `MERITUM_TRANSCRIPTION_PROJECT` (ten sam projekt), więc nagrania transkrybuje Chirp 3 w multi-regionie `eu` (ADR-30), a nie stub. Z poświadczeniami GCP worker (dev i prd) dostaje też `MERITUM_OCR_PROVIDER=vision` i `MERITUM_OCR_PROJECT` (infra#55): zrzuty ekranu czyta Cloud Vision pod adresem UE `eu-vision.googleapis.com` (adres zaszyty w core, ADR-30), a API `vision.googleapis.com` włącza `gcp/workload-identity/` (uprawnienia z `serviceUsageConsumer`, Vision nie ma roli wywołującego). Worker (dev i prd) dostaje też `MERITUM_ADMIN_EMAILS` (infra#51), tę samą listę co backend, do powiadomień `case_assigned`: z sekretów repo `MERITUM_ADMIN_EMAILS_DEV` i `MERITUM_ADMIN_EMAILS_PRD` przez workflow Platform (`m_admin_env`); bez sekretu linii nie ma, a workflow ostrzega. Worker (dev i prd) dostaje też `MERITUM_FACT_CHECK_PROVIDER=google` i `MERITUM_FACT_CHECK_API_KEY` (infra#53, Google Fact Check Tools API): klucz ograniczony do `factchecktools.googleapis.com` z sekretów repo `MERITUM_FACT_CHECK_API_KEY_DEV` i `MERITUM_FACT_CHECK_API_KEY_PRD` przez workflow Platform (`m_fact_check_env`); bez sekretu obu linii nie ma, a workflow ostrzega. Linie aplikacji pisze `m_app_env`, `m_pii_env`, `m_web_search_env`, `m_transcription_env` i `m_ocr_env` z `platform/lib.sh` (lokalny test: `platform/test-app-env.sh`; te same klucze w `app.env` trafiają do pliku później i wygrywają); hasła w `~/meritum/db.env`, wspólne sekrety aplikacji opcjonalnie w `~/meritum/app.env` |
| Gateway | `meritum-gateway` (nginx) na `172.17.0.1:18095`: `meritum.gburek.app` → `meritum-web-prd`, `meritum-dev.gburek.app` → `meritum-web-dev`, `meritum-<platforma>.gburek.app` → `meritum-mocks-prd` (platformy: x, facebook, instagram, reddit, tiktok, discord; lokalny test: `platform/test-mocks.sh`) |
| Cloudflare | reguły tunelu i rekordy DNS dla wszystkich 8 adresów (sekret repo `CLOUDFLARE_API_TOKEN`: token konta `meritum-platform-deploy`, Tunnel Edit i DNS Edit na gburek.app, wygasa 2026-12-21; zmienne repo `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ZONE_ID`) |

Porty 18080 i 18081 należą do TuttiTrip, 18090 do ExactDocs. Skrypt dotyka tylko zasobów z prefiksem `meritum` i hostów `meritum(-*).gburek.app`.

### Układ bazy: `app_<env>`, `corpus` i `meritum_dbos_<env>`

Ten sam układ ma `docker-compose.yml` w monorepo (monorepo#1) i GCP (infra#5): jedna instancja PostgreSQL, w bazie `meritum` schematy `app_dev` i `app_prd` oraz wspólny `corpus`, a tabele DBOS w bazach `meritum_dbos_dev` i `meritum_dbos_prd`. API i worker tego samego środowiska czytają jeden schemat aplikacji, tabele zakłada worker (migracje w jego deployu). Ponowne uruchomienie `setup.sh` niczego nie usuwa, a hasła ról zostają w `~/meritum/db.env`.

Test lokalny, poza CI pull requestów: `onprem/dellpromaxgb10/platform/test-db.sh` startuje obraz `meritum-postgres`, stosuje układ dwa razy i sprawdza schematy, bazy i uprawnienia ról.

Przejście ze starego układu (schematy `api_<env>` i `worker_<env>`, tabele DBOS w `worker_<env>`). Są tam tylko dane testowe, więc kolejność jest prosta:

1. Kopia na serwerze: `docker exec meritum-postgres pg_dumpall -U meritum | gzip >~/meritum/backups/pg_dumpall-przed-app-schema.sql.gz`.
2. Workflow Platform (scalenie tej zmiany na `main` albo ręcznie) tworzy `app_dev`, `app_prd`, bazy DBOS i nowe pliki env. Stare schematy zostają.
3. Wdrożenie na nowym układzie (worker#35, core#23), w każdym środowisku najpierw worker, potem API. Worker robi `dbos migrate` w `meritum_dbos_<env>` i migracje w `app_<env>`. Pliki env API wskazują nową bazę DBOS od razu po kroku 2, więc API wdrożone przed workerem nie ma jeszcze schematu `dbos` i nie zleci zadań.
4. Po udanym wdrożeniu usunięcie starych schematów, ręcznie:
   `docker exec meritum-postgres psql -U meritum -d meritum -c 'DROP SCHEMA api_dev, api_prd, worker_dev, worker_prd CASCADE'`.
   Stary `search_path` ustawiony na całą rolę przestaje działać (ustawienie `IN DATABASE meritum` ma pierwszeństwo), ale można go wyczyścić: `ALTER ROLE meritum_api_dev RESET search_path` i tak samo dla pozostałych trzech ról.

#### Wspólny schemat `corpus`

Korpus wczytujemy raz i czytają go oba środowiska, a sprawdzenia, sprawy i konta zostają w `app_<env>`. Zapisuje do `corpus` i robi jego migracje tylko `meritum_worker_prd`, czyli deploy workera z gałęzi `main`. Deploy z `develop` ma pomijać migracje `corpus` i to logować (worker#32); do tego czasu rola `meritum_worker_dev` i tak nie ma w `corpus` prawa do DDL. Pozostałe role aplikacji mają `USAGE` i `SELECT`, także na tabelach, które worker `prd` założy później (`ALTER DEFAULT PRIVILEGES`). `corpus` nie jest w `search_path`, więc zapytania i migracje podają nazwę schematu: `corpus.<tabela>` (także tabela wersji narzędzia migracji, inaczej trafi do `app_prd`). DDL w `corpus` robimy tylko jako `meritum_worker_prd`: tabeli założonej przez `meritum` pozostałe role nie przeczytają do następnego `setup.sh`.

Migracje `corpus` muszą być wstecznie zgodne, bo dev może działać na starszym kodzie niż prd:

- dozwolone jest tylko dodawanie: nowe tabele, nowe kolumny (z wartością domyślną albo dopuszczające `NULL`), nowe indeksy;
- kolumnę lub tabelę usuwamy (albo zmieniamy jej nazwę lub typ) dopiero wtedy, gdy kod na `main` i na `develop` przestał jej używać, osobną migracją w kolejnym wdrożeniu;
- migracja nie przepisuje danych tak, by stary kod czytał je inaczej niż przedtem.

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

`gcp/search/` zakłada data store Vertex AI Search do wyszukiwania na żywo (US-KOR-04, ADR-07): website data store w lokalizacji `global`, wzorce INCLUDE z katalogu źródeł z meritum-core i wyszukiwarkę w edycji Enterprise. Szczegóły, koszt i migracja do `eu`: [README](gcp/search/README.md).

## Stan Terraform na GCP

Stan modułów z `gcp/` leży w prywatnym buckecie `agro-prj-sandbox-sd-2332277-meritum-tfstate` (`europe-central2`, wersjonowanie obiektów, publiczny dostęp zablokowany), każdy moduł pod własnym prefiksem: `app`, `gh-actions`, `search`, `storage`, `state`, `workload-identity`. Bucket zakłada moduł `gcp/state/` i trzyma w nim także własny stan. Backend GCS blokuje stan na czas `plan` i `apply`, więc dwie osoby nie nadpiszą go sobie nawzajem. Stan `gh-actions` zawiera wrażliwe wartości (hash hasła admina, klucz SSH, token rejestracji runnera), a czyta go każdy z dostępem do odczytu obiektów w projekcie.

Druga osoba potrzebuje tylko dostępu do projektu: `gcloud auth application-default login`, potem w czystym klonie `terraform -chdir=gcp/<moduł> init` i `plan`. Lokalnych plików `terraform.tfstate` nie ma i nie trzeba ich przekazywać.

Poprzednią wersję stanu przywraca się z historii obiektu: `gcloud storage ls -a gs://agro-prj-sandbox-sd-2332277-meritum-tfstate/<prefiks>/default.tfstate`, potem `gcloud storage cp` wybranej generacji na `default.tfstate`.

Bloki `backend "gcs"` nie przyjmują zmiennych, więc nazwa bucketu jest wpisana w każdy moduł; `project_id` w `gcp/state` musi być `agro-prj-sandbox-sd-2332277` (test modułu sprawdza, że dla tego projektu nazwa wychodzi taka jak w blokach backend; bloków w innych modułach nie czyta).

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

Przeniesienie lokalnego stanu modułu do bucketu (raz na moduł): `terraform -chdir=gcp/<moduł> init -migrate-state`, potem `plan` musi pokazać `No changes`. Dopiero wtedy lokalny `terraform.tfstate` można usunąć.

## Tożsamość GCP backendu i workera (Workload Identity Federation)

Backend i worker działają na dellpromaxgb10, poza GCP, a do bucketu i Vertex AI wchodzą jako konta `meritum-backend`, `meritum-worker` i `meritum-speech` (`gcp/storage/`). Nie mają kluczy JSON kont serwisowych: każdy kontener ma certyfikat X.509 serwera, Google wymienia go przez mTLS na token ważny godzinę, a biblioteka klienta (`google-auth` od 2.39) sama go odnawia.

### Skąd serwer bierze tożsamość: certyfikat X.509

Wybraliśmy certyfikat serwera zamiast tokenu OIDC z GitHub Actions. Token OIDC można pobrać tylko w trakcie joba deployu, a kontener backendu działa dniami i odnawia token GCP co godzinę. Musiałby dostawać świeży token OIDC z workflow uruchamianego według harmonogramu, a ten w GitHub Actions bywa opóźniony o kwadrans i więcej. Certyfikat leży na dysku serwera, a biblioteka sama wymienia go na token GCP.

| Element | Szczegóły |
| --- | --- |
| Terraform | `gcp/workload-identity/`: pula `meritum-onprem`, dostawca X.509 `dellpromaxgb10` z CA serwera jako jedynym zaufanym certyfikatem, warunek wpuszczający tylko CN `meritum-backend`, `meritum-worker`, `meritum-speech` i `roles/iam.workloadIdentityUser` dla każdego konta wyłącznie dla certyfikatu o tej samej nazwie; `meritum-backend` i `meritum-worker` mają też `roles/dlp.user` i `roles/serviceusage.serviceUsageConsumer` (adapter PII wysyła `x-goog-user-project`), a `meritum-worker` także `roles/discoveryengine.viewer` do wołania `:search` na aplikacji `meritum-live-search` (infra#42) oraz `roles/speech.client` przy włączonym `speech.googleapis.com` (transkrypcja Chirp 3) i `roles/aiplatform.user` do embeddingów korpusu w Vertex AI (infra#57) |
| CA serwera | `~meritum-runner/meritum/gcp/ca/` (klucz `ca.key`, 600; nie trafia do kontenerów), ECDSA P-256, ważny 5 lat |
| Certyfikaty usług | `~meritum-runner/meritum/gcp/<konto>/`: `cert.pem`, `key.pem`, `certificate_config.json` i `credentials.json` (`type: external_account`). Ważne 365 dni (Google przyjmuje najwyżej 390) |
| Dostarczenie | workflow Platform (`setup.sh`, funkcje w `platform/wif.sh` i `m_pii_env` w `lib.sh`) tworzy pliki i dopisuje do `api-<env>.env` i `worker-<env>.env`: `GOOGLE_CLOUD_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS`, `MERITUM_GCP_MOUNTS`, a workerowi `MERITUM_SPEECH_CREDENTIALS` oraz `MERITUM_PII_*` dla SDP, a workerowi dev `MERITUM_WEB_SEARCH_*` (`m_web_search_env` w `lib.sh`), oraz `MERITUM_TRANSCRIPTION_*` dla Chirpa. Potrzebuje zmiennych repo `GCP_PROJECT_ID` i `GCP_PROJECT_NUMBER`; bez nich pomija ten krok z ostrzeżeniem |
| Kontener | deploy aplikacji ma montować każdy wpis z `MERITUM_GCP_MOUNTS` (`-v <host>:/etc/meritum/gcp/<konto>:ro`): backend#54 i worker#55, do tego czasu `GOOGLE_APPLICATION_CREDENTIALS` w kontenerze wskazuje na plik, którego nie ma. Backend dostaje tylko katalog `meritum-backend`, worker `meritum-worker` i `meritum-speech`, więc backend nie podszyje się pod workera |

### Wdrożenie

1. Zmienne repo (raz): `gh variable set GCP_PROJECT_ID -b <projekt>` i `gh variable set GCP_PROJECT_NUMBER -b "$(gcloud projects describe <projekt> --format='value(projectNumber)')"`.
2. Workflow Platform (scalenie na `main` albo Run workflow) zakłada CA i certyfikaty. W logu jest odcisk SHA-256 CA.
3. Terraform, ręcznie (CI robi tylko `fmt`, `validate` i `terraform test` na atrapie dostawcy):

   ```bash
   cp gcp/workload-identity/terraform.tfvars.example gcp/workload-identity/terraform.tfvars
   # project_id i trust_anchor_pem: publiczny certyfikat CA, ssh dellpromaxgb10 sudo cat ~meritum-runner/meritum/gcp/ca/ca.pem
   terraform -chdir=gcp/workload-identity init
   terraform -chdir=gcp/workload-identity plan -out=wif.tfplan
   terraform -chdir=gcp/workload-identity apply wif.tfplan
   ```

4. Sprawdzenie na serwerze, poza CI: `sudo -iu meritum-runner <repo>/onprem/dellpromaxgb10/platform/verify-wif.sh` zapisuje obiekt testowy jako backend, usuwa go jako worker i sprawdza, że na dysku nie ma klucza konta serwisowego. Test samych plików bez GCP: `platform/test-wif.sh`.

### Rotacja

- Certyfikaty usług: `setup.sh` wystawia nowy 30 dni przed wygaśnięciem, z nowym kluczem prywatnym, podpisany tym samym CA, bez zmian w Terraform. Workflow Platform uruchamia się sam raz w miesiącu, więc plik na dysku nie wygaśnie bez odnowienia. Kontenery backendu i workera trzeba zrestartować (najprościej ich deployem) w ciągu 30 dni od wymiany, bo biblioteka może trzymać stary certyfikat w pamięci, a ten po 30 dniach wygasa.
- CA (raz na 5 lat albo po wycieku): `rm -rf ~meritum-runner/meritum/gcp` na serwerze, workflow Platform, nowy `trust_anchor_pem` w `terraform.tfvars` i `apply`, potem restart kontenerów backendu i workera. Między krokiem 2 a `apply` kontenery nie mają dostępu.

### Cofnięcie dostępu

- Cały serwer od razu: `disabled = true` w `terraform.tfvars` i `apply` (albo `gcloud iam workload-identity-pools providers update dellpromaxgb10 --workload-identity-pool=meritum-onprem --location=global --disabled`). Tokeny wydane wcześniej działają do godziny.
- Jedna usługa: usunięcie jej konta z `service_accounts` w `terraform.tfvars` i `apply` (znika jej `workloadIdentityUser`).
- Wyciek klucza z serwera: wyłączenie dostawcy, potem rotacja CA jak wyżej.

## API, worker i PostgreSQL w GCP (europe-central2)

`gcp/app/` opisuje docelowe środowisko demo (ADR-14), przygotowane na czas po hackathonie. **Nie jest wdrożone: na hackathon API, worker i PostgreSQL zostają na serwerze zespołu w Polsce (meritum.gburek.app).** Migrację zrobi wdrożenie przez CI/CD (infra#14). Środowiska: zmienna `environments`, domyślnie `["prd"]` (`prd` jest obowiązkowe); `["dev", "prd"]` dodaje drugie API, drugą grupę workerów oraz `app_dev` i `meritum_dbos_dev`.

| Element | Szczegóły |
| --- | --- |
| API | Cloud Run `meritum-api-<env>` w europe-central2, konto `meritum-backend` (z `gcp/storage/`), skalowanie od 0 do `api_max_instances` (domyślnie 3). Do bazy przez Direct VPC egress, reszta ruchu wychodzi bezpośrednio. Do pierwszego wdrożenia działa obraz zastępczy `cloudrun/container/hello`; obraz ustawia deploy (infra#14), Terraform go nie nadpisuje |
| Worker | grupa maszyn `meritum-worker-<env>` (Container-Optimized OS, `e2-medium`) w strefach europe-central2, konto `meritum-worker`, autoskalowanie na CPU od 1 do `worker_max_replicas` (domyślnie 3). Przy starcie maszyna pobiera `meritum-worker:<env>` z Artifact Registry, robi `dbos migrate` i uruchamia kontener. Bez publicznego IP, ruch do internetu przez Cloud NAT |
| PostgreSQL | maszyna `meritum-postgres` (COS, `e2-medium`, bez publicznego IP) z kontenerem z obrazu `meritum-postgres` z infra#7 (`postgres_image`, przypięty tag). Cloud SQL odpada, bo nie przyjmie polskiego słownika (ADR-04). Dane na osobnym dysku `meritum-pgdata`. Przy każdym starcie `postgres-startup.sh` stosuje ten sam układ co serwer zespołu (`onprem/dellpromaxgb10/platform/db.sh`): baza `meritum` ze schematami `app_<env>`, bazy `meritum_dbos_<env>`, role `meritum_api_<env>` i `meritum_worker_<env>` oraz wspólny schemat `corpus`, którego właścicielem jest `meritum_worker_prd` (dlatego `environments` musi zawierać `prd`). Port 5432 otwarty tylko dla podsieci aplikacji |
| Kopie zapasowe | codzienna migawka dysku `meritum-pgdata` o 02:00 UTC, przechowywana 7 dni (`backup_retention_days`) w europe-central2; migawki zostają po usunięciu dysku. Migawka działającej bazy jest spójna jak po nagłym wyłączeniu: PostgreSQL odtwarza ją z WAL przy starcie. Bez archiwizacji WAL można stracić zmiany z najwyżej doby |
| Sekrety | Secret Manager, replika tylko w europe-central2: `meritum-postgres-password` oraz `meritum-<api\|worker>-<env>-<database-url\|dbos-url>`. Hasła generuje Terraform jako wartości ulotne i zapisuje je polem tylko do zapisu, więc nie ma ich w stanie ani w planie. Nowe hasła: zwiększ `db_password_version`, `apply`, potem restart maszyny `meritum-postgres` (ustawia hasła ról i administratora) i workerów oraz nowa rewizja API |
| Konta serwisowe | API czyta tylko swoje dwa sekrety; worker swoje dwa, `roles/aiplatform.user` (Vertex AI) i odczyt obrazów; `meritum-postgres` hasło administratora, adresy baz ról i odczyt obrazów. Maszyny piszą logi (`roles/logging.logWriter`) |
| Vertex AI | tylko region GCP w UE albo multi-region `eu` (lista w walidacji zmiennej; bez Londynu i Zurychu); worker dostaje `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` (`vertex_location`, domyślnie `europe-west4`; zmień na region UE wybranego modelu) i `GOOGLE_GENAI_USE_VERTEXAI=true` |
| Maskowanie PII (SDP) | API w Cloud Run i worker na VM dostają `MERITUM_PII_GATE=sdp`, `MERITUM_PII_PROJECT` i `MERITUM_PII_LOCATION=europe-central2` (ten sam kontrakt co on-prem; core#90). Konta `meritum-backend` i `meritum-worker` muszą mieć uprawnienia DLP — patrz `gcp/workload-identity/` |
| Obrazy | Artifact Registry `europe-central2-docker.pkg.dev/<projekt>/meritum` (output `images`): `meritum-postgres:<tag>`, `meritum-worker:<env>`, obraz API |
| Budżet i limity | budżet miesięczny `monthly_budget` (domyślnie 100 w walucie konta rozliczeniowego) z alertami przy 50, 90 i 100 %. Budżet tylko ostrzega; twarde limity to `api_max_instances` i `worker_max_replicas`, a nadmiar zapytań czeka w kolejce DBOS albo dostaje HTTP 429 (ADR-18) |

### Koszt utrzymania

Szacunek z cennika dla europe-central2 (ceny katalogowe bez rabatów, do sprawdzenia w kalkulatorze GCP), dla `environments = ["prd"]`:

| Pozycja | Miesięcznie |
| --- | --- |
| `meritum-postgres` e2-medium, całą dobę | ok. 32 USD |
| worker e2-medium, 1 maszyna (każda kolejna przy obciążeniu tyle samo) | ok. 32 USD |
| dyski pd-balanced (20 GB danych i dyski systemowe) i migawki | ok. 7 USD |
| Cloud NAT (2 maszyny) i ruch wychodzący | ok. 3 USD + 0,045 USD/GB |
| API na Cloud Run, od 0 instancji | w ramach darmowego limitu przy ruchu demo |
| Secret Manager, Artifact Registry | poniżej 1 USD |

Razem ok. 75 USD miesięcznie (ok. 0,10 USD/h), przy pełnym skalowaniu workerów do 3 maszyn ok. 140 USD. Wywołania Vertex AI liczą się osobno, za tokeny. Drugie środowisko (`dev`) dokłada głównie jedną maszynę workera.

### Cloudflare przed API

Cloudflare stoi przed API tak jak dziś przed serwerem zespołu: kończy TLS, chroni przed DDoS i ma reguły limitów. Konfiguracja w strefie gburek.app (ręcznie albo w infra#14):

1. Rekord `CNAME` nazwy API (np. `meritum-api.gburek.app`) na host z outputu `api_urls` (`meritum-api-prd-….run.app`), z proxy Cloudflare.
2. Origin Rule dla tej nazwy: nadpisanie nagłówka `Host` na host `run.app` (Cloud Run kieruje ruch po nazwie hosta).
3. SSL/TLS w trybie Full (strict): Cloud Run ma ważny certyfikat dla `run.app`.
4. Reguła Rate limiting dla ścieżek `/api/v1/` po adresie IP, np. 20 żądań na 10 s; własny licznik API (ADR-18) zostaje drugą warstwą.

Ograniczenie: adres `run.app` zostaje publiczny (bez load balancera nie da się wpuścić tylko Cloudflare), więc limity w samym API muszą działać także bez Cloudflare. Rejestr podmiotów przetwarzających (design-system, `copy/privacy.json`) ma już wiersze Cloudflare i GCP europe-central2; przy migracji (infra#14) cel wiersza Cloudflare zmienia się z tunelu do serwera zespołu na proxy przed API w GCP.

### Uruchomienie

Najpierw `gcp/storage/` (konta serwisowe `meritum-backend` i `meritum-worker`). Potrzebne API projektu `cloudresourcemanager.googleapis.com` i `serviceusage.googleapis.com` (resztę włącza moduł) i uprawnienie do budżetów na koncie rozliczeniowym. Stan leży w buckecie stanu pod prefiksem `app` (sekcja „Stan Terraform na GCP”). `terraform apply` tylko ręcznie:

```bash
cp gcp/app/terraform.tfvars.example gcp/app/terraform.tfvars   # project_id, billing_account, postgres_image
terraform -chdir=gcp/app init
terraform -chdir=gcp/app plan -out=app.tfplan
terraform -chdir=gcp/app apply app.tfplan
```

Obraz bazy trzeba raz skopiować z GHCR do Artifact Registry (po `docker login ghcr.io` i `gcloud auth configure-docker europe-central2-docker.pkg.dev`):

```bash
docker buildx imagetools create \
  -t europe-central2-docker.pkg.dev/<projekt>/meritum/meritum-postgres:<tag> \
  ghcr.io/meritum-hacknation2026/meritum-postgres:<tag>
```

Dostęp do maszyn tylko przez IAP: `gcloud compute ssh meritum-postgres --zone europe-central2-a --tunnel-through-iap`. Log startu: `sudo journalctl -u google-startup-scripts`. Wyłączenie kosztów: `terraform -chdir=gcp/app destroy` (migawki bazy zostają, usuwa się je ręcznie).

CI (`.github/workflows/terraform.yml`) sprawdza `gcp/app` tak jak pozostałe moduły (`fmt`, `validate`, `terraform test` na atrapie dostawcy) i dodatkowo `shellcheck` jego skryptów. Workflow rusza też po zmianie `onprem/dellpromaxgb10/platform/*.sh`, bo maszyna bazy dostaje `lib.sh` i `db.sh` w metadanych.
