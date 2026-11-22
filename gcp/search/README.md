# Vertex AI Search do wyszukiwania na żywo (`gcp/search`)

Moduł zakłada website data store Vertex AI Search (basic website search), wzorce domen z katalogu źródeł i wyszukiwarkę, z której korzysta adapter wyszukiwania w meritum-core (core#34). US-KOR-04, F-13, ADR-07, ADR-14.

| Element | Szczegóły |
| --- | --- |
| Data store | `meritum-live-search`, `content_config = PUBLIC_WEBSITE`, lokalizacja `global`, bez advanced indexing |
| Wzorce | `google_discovery_engine_target_site`, typ `INCLUDE`, `exact_match = false` (obejmuje każdą stronę pod podanym adresem), jeden na pozycję katalogu |
| Wyszukiwarka | `google_discovery_engine_search_engine` `meritum-live-search`, edycja Enterprise (`SEARCH_TIER_ENTERPRISE`) |
| API | włącza `discoveryengine.googleapis.com` (wyłączenie modułu go nie wyłącza) |

Data store służy tylko wyszukiwaniu na żywo w chwili sprawdzenia. Wczytywanie korpusu z niego nie korzysta: korpus pobiera worker prosto ze źródeł do PostgreSQL (ADR-32).

## Wzorce z katalogu

Lista domen nie jest wpisana ręcznie. Moduł czyta `catalog.yaml` z meritum-core (`src/meritum_core/corpus/catalog/catalog.yaml`, core#22) i dla każdej pozycji bez `excluded: true` tworzy wzorzec z jej pola `domain`. Pozycja pod ścieżką innej pozycji (np. `www.gov.pl/web/mswia/regionalny-system-ostrzegania` pod `www.gov.pl/web/mswia`) nie dostaje osobnego wzorca, bo już ją obejmuje wzorzec nadrzędny.

Basic website search przyjmuje najwyżej 50 wzorców. Gdy katalog da ich więcej, warunek na data store zatrzymuje `terraform plan` z komunikatem o limicie. Dlatego wszystkie pozycje pod `www.gov.pl/web/` (ministerstwa i służby na gov.pl) dzielą jeden wzorzec `www.gov.pl/web` (zmienna `shared_prefix`). Wyszukiwarka może wtedy zwrócić stronę innego urzędu z gov.pl, ale adapter w meritum-core i tak przepuszcza tylko adresy z domen katalogu. Katalog z core#149 daje 41 wzorców (57 pozycji bez wykluczenia).

Domyślna ścieżka `catalog_path` wskazuje submoduł `core/` obok `infra/` w monorepo. W osobnym klonie meritum-infra trzeba ją podać: `-var catalog_path=<ścieżka do catalog.yaml>`. Po zmianie katalogu w core wystarczy ponowny `plan` i `apply`.

## Lokalizacja, koszt i migracja do `eu`

- Lokalizacja `global`: basic website search działa tylko w niej, więc zapytanie (zamaskowane twierdzenie) wychodzi poza UE. Bramka danych osobowych maskuje je przed wysłaniem.
- Koszt: 4 USD za 1 000 zapytań, po 10 000 darmowych zapytań miesięcznie.
- Czas indeksowania basic website search i warunki przechowywania wyników nie są opisane w dokumentacji Google (załącznik B).
- Droga do `eu`: lokalizacja `eu` wymaga advanced website indexing (`create_advanced_site_search = true`), a ten weryfikacji własności każdej domeny w Google Search Console. Dla domen katalogu (gov.pl, europa.eu i inne cudze serwisy) tego nie zrobimy, więc migracja jest możliwa tylko dla domen, które zweryfikujemy. Kroki: nowy data store w `eu` z advanced indexing, wzorce tylko dla zweryfikowanych domen, wyszukiwarka w `eu`, przełączenie adaptera na nowy serving config, potem usunięcie data store `global`. Data store nie da się przenieść między lokalizacjami.

## Zmienne

| Zmienna | Domyślnie | Opis |
| --- | --- | --- |
| `project_id` | (wymagana) | projekt GCP |
| `catalog_path` | `../../../core/src/meritum_core/corpus/catalog/catalog.yaml` | katalog źródeł z meritum-core |
| `data_store_id` | `meritum-live-search` | id data store i wyszukiwarki |
| `shared_prefix` | `www.gov.pl/web` | prefiks, którego pozycje katalogu dzielą jeden wzorzec |

Wyjścia: `data_store_id`, `serving_config` (pełna nazwa serving config dla adaptera core#34) i `patterns` (lista wzorców).

## Apply

Stan leży w buckecie stanu, prefiks `search`. Potrzebne `gcloud auth application-default login` na koncie z dostępem do projektu; Discovery Engine wymaga projektu do rozliczania limitów, więc dostawca ma `user_project_override`. W projekcie musi być włączone `serviceusage.googleapis.com`. `terraform apply` tylko ręcznie:

```bash
cp gcp/search/terraform.tfvars.example gcp/search/terraform.tfvars   # project_id
terraform -chdir=gcp/search init
terraform -chdir=gcp/search plan -out=search.tfplan
terraform -chdir=gcp/search apply search.tfplan
```

CI (`.github/workflows/terraform.yml`) uruchamia `terraform fmt -check`, `terraform validate` i `terraform test` (`tests/`, plan na atrapie dostawcy z katalogiem z `tests/fixtures/`, bez poświadczeń).
