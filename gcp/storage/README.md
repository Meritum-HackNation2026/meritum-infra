# Bucket na pliki od obywateli (`gcp/storage`)

Moduł zakłada prywatny bucket Cloud Storage na nagrania i obrazy przesłane do sprawdzenia (ADR-31) oraz konta serwisowe, które z niego korzystają.

| Element | Szczegóły |
| --- | --- |
| Bucket | `<project_id>-meritum-uploads`, region `europe-central2` (Warszawa), klasa `STANDARD` |
| Dostęp | publiczny zablokowany (`public_access_prevention = enforced`), jednolity dostęp na poziomie bucketu, bez ACL obiektów |
| Retencja | reguła cyklu życia usuwa obiekt 30 dni po zapisie, czyli po retencji zapisu sprawdzenia (`retention_days`) |
| `meritum-backend` | `roles/storage.objectCreator`: tylko zapis nowych obiektów |
| `meritum-worker` | `roles/storage.objectViewer` i własna rola `meritumObjectDeleter` (`storage.objects.delete`) |
| `meritum-speech` | `roles/storage.objectViewer`: Speech-to-Text w trybie batch czyta nagrania dłuższe niż około minuty z `gs://` |

Rejestr podmiotów przetwarzających (design-system/002): Google Cloud przechowuje te pliki w `europe-central2` przez najwyżej 30 dni; Speech-to-Text przetwarza je w tym samym regionie.

## Zmienne

| Zmienna | Domyślnie | Opis |
| --- | --- | --- |
| `project_id` | (wymagana) | projekt GCP z bucketem |
| `region` | `europe-central2` | region bucketu |
| `bucket_suffix` | `meritum-uploads` | nazwa bucketu to `<project_id>-<suffix>` (globalnie unikalna) |
| `retention_days` | `30` | po ilu dniach obiekt znika (co najmniej 1) |

Wyjścia: `bucket` (nazwa) i `service_accounts` (adresy kont `backend`, `worker`, `speech`).

## Apply

Stan leży w buckecie stanu, prefiks `storage` (README w katalogu głównym, „Stan Terraform na GCP”). Potrzebne `gcloud auth application-default login` na koncie z dostępem do projektu. `terraform apply` tylko ręcznie:

```bash
cp gcp/storage/terraform.tfvars.example gcp/storage/terraform.tfvars   # project_id
terraform -chdir=gcp/storage init
terraform -chdir=gcp/storage plan -out=storage.tfplan
terraform -chdir=gcp/storage apply storage.tfplan
```

CI (`.github/workflows/terraform.yml`) uruchamia `terraform fmt -check`, `terraform validate` i `terraform test` (`tests/`, plan na atrapie dostawcy, bez poświadczeń).
