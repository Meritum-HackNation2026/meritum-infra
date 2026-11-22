# Worker e-mail do moderatorów

Worker Cloudflare `meritum-email` wysyła moderatorowi e-mail o nowej albo zaktualizowanej sprawie (US-POW-05, US-MOD-01, F-26, ADR-14, ADR-29). Wiązanie `send_email` działa tylko w Workerze, więc backend (adapter e-mail z meritum-backend#34) woła go przez HTTPS, a Worker wysyła wiadomość.

## Żądanie

`POST https://meritum-email-<dev|prd>.cypkowski.workers.dev/` z treścią JSON:

```json
{
  "to": "moderator@example.com",
  "case": "S-42",
  "panel_url": "https://meritum.gburek.app/panel/sprawy/S-42"
}
```

Nagłówki podpisu (HMAC-SHA256, sekret `SIGNING_SECRET` wspólny z backendem):

- `X-Meritum-Timestamp`: czas w sekundach Unix; Worker przyjmuje odchylenie do 300 s, co ogranicza powtórki,
- `X-Meritum-Signature`: `sha256=` i szesnastkowy HMAC tekstu `<timestamp>.<surowa treść>`.

```python
timestamp = str(int(time.time()))
signature = hmac.new(secret, f"{timestamp}.{body}".encode(), hashlib.sha256).hexdigest()
headers = {"X-Meritum-Timestamp": timestamp, "X-Meritum-Signature": f"sha256={signature}"}
```

| Kod | Kiedy                                                                                                                                                                                                               |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 202 | wiadomość wysłana                                                                                                                                                                                                   |
| 400 | treść dłuższa niż 4096 znaków (sprawdzana przed podpisem), adres spoza `MODERATOR_ADDRESSES`, numer sprawy inny niż litery, cyfry i `-` (do 64 znaków), link spoza `PANEL_ORIGINS` albo zła treść; nic nie wychodzi |
| 401 | brak podpisu, zły podpis albo czas poza oknem 300 s (powtórka w tym oknie przejdzie, moderator dostanie wtedy drugi e-mail)                                                                                         |
| 405 | metoda inna niż `POST`                                                                                                                                                                                              |
| 502 | Cloudflare odrzucił wysyłkę (kod błędu w logu Workera, bez adresu)                                                                                                                                                  |

Temat to tekst `notifications.kind.case_assigned` z `copy/pl.json` („Nowa albo zaktualizowana sprawa {case}.”), treść to ten sam tekst i link do panelu. Wiadomość nie zawiera danych obywatela ani identyfikatorów kanałów.

## Konfiguracja

| Nazwa                 | Gdzie           | Co                                                                                       |
| --------------------- | --------------- | ---------------------------------------------------------------------------------------- |
| `SEND_EMAIL`          | `wrangler.toml` | wiązanie `send_email`                                                                    |
| `FROM_ADDRESS`        | `wrangler.toml` | nadawca `meritum@gburek.app`, w domenie z włączonym Email Routing                        |
| `PANEL_ORIGINS`       | `wrangler.toml` | dozwolone początki linku: `https://meritum.gburek.app`, `https://meritum-dev.gburek.app` |
| `SIGNING_SECRET`      | sekret Workera  | wspólny z backendem, np. `openssl rand -hex 32`                                          |
| `MODERATOR_ADDRESSES` | sekret Workera  | adresy moderatorów po przecinku, zweryfikowane w Email Routing                           |

Listy adresów nie ma w `wrangler.toml`, bo adresy moderatorów to dane osobowe, a te nie trafiają do repozytorium. Z tego samego powodu wiązanie nie ma `allowed_destination_addresses`. Bez włączonego Email Sending Cloudflare i tak dostarcza wyłącznie na adresy zweryfikowane w koncie, a Worker odrzuca kodem 400 każdy adres spoza sekretu. Po włączeniu Email Sending dla domeny Cloudflare przestaje ograniczać odbiorców i jedynym filtrem zostaje ten sekret.

Workery mają publiczne adresy `workers.dev` (`workers_dev = true`); każde żądanie bez ważnego podpisu dostaje 401.

## Weryfikacja adresów w Email Routing (raz na adres)

1. Dashboard Cloudflare → konto → Email → Email Routing dla `gburek.app`. Jeśli routing nie jest włączony, włącz go (Cloudflare doda rekordy MX i SPF; sprawdź wcześniej, czy domena nie odbiera już poczty gdzie indziej).
2. Destination addresses → Add destination address → adres moderatora.
3. Moderator klika link z wiadomości od Cloudflare. Do tego czasu adres ma stan „Pending” i wysyłka na niego się nie uda.
4. Dopisz adres do sekretu `MODERATOR_ADDRESSES` (krok 3 wdrożenia).

## Wdrożenie (ręcznie)

Token `CLOUDFLARE_API_TOKEN` w sekretach repo ma tylko uprawnienia Tunnel i DNS, więc workflow `Email Worker` jedynie sprawdza kod. Wdraża osoba z dostępem do konta Cloudflare:

```bash
cd cloudflare/email
pnpm install
pnpm wrangler login                                # albo CLOUDFLARE_API_TOKEN z uprawnieniem Workers Scripts Edit
pnpm wrangler deploy --env dev                     # meritum-email-dev; prd analogicznie
pnpm wrangler secret put SIGNING_SECRET --env dev  # wartość wklejana w terminalu, nigdy do repozytorium
pnpm wrangler secret put MODERATOR_ADDRESSES --env dev  # np. a@example.com,b@example.com
```

Każde środowisko backendu ma własny Worker (`meritum-email-dev`, `meritum-email-prd`) z własnym `SIGNING_SECRET`, a `PANEL_ORIGINS` przyjmuje tylko panel swojego środowiska. Adres Workera trafia do zmiennej `EMAIL_WORKER_URL_{DEV,PRD}`, a `SIGNING_SECRET` do sekretu `MERITUM_EMAIL_WORKER_SIGNING_SECRET_{DEV,PRD}` w meritum-backend. Zmiana listy moderatorów to ponowne `wrangler secret put MODERATOR_ADDRESSES --env <dev|prd>`, bez nowego wdrożenia kodu.

Konto ma aplikację Cloudflare Access na `*.cypkowski.workers.dev`, która bez wyjątku przekierowałaby backend na logowanie (302). Hosty obu Workerów są dlatego w aplikacji Access „meritum-email Worker (bypass, HMAC in Worker)” z polityką Bypass; nowy host trzeba tam dopisać, bo dostęp i tak sprawdza podpis HMAC w Workerze.

## Region i rejestr podmiotów przetwarzających

Wpis do rejestru z meritum-design-system#8 (Cloudflare, Email Workers):

| Dostawca                            | Kraj lub region                                                                                                            | Dane                                                  | Cel                                                           |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------- |
| Cloudflare (Workers, Email Routing) | sieć globalna Cloudflare, bez przypięcia regionu (Regional Services wymaga planu Enterprise); dalej serwer poczty odbiorcy | adres e-mail moderatora, numer sprawy, link do panelu | powiadomienie moderatora o nowej albo zaktualizowanej sprawie |

W podsumowaniu Email Routing wiadomości z Workera mają stan „dropped”, nawet gdy doszły; wynik wysyłki pokazują metryki i logi Email Sending.

Worker niczego nie zapisuje; dane są tylko w wiadomości i w logach wysyłki Cloudflare.

## Testy i kontrole

```bash
pnpm biome ci . && pnpm typecheck && pnpm test && pnpm knip
```

`pnpm test` (`node --test`) uruchamia testy Workera na fałszywym wiązaniu `send_email`, bez prawdziwej poczty, oraz testy architektury z `tests/architecture/` (kopie z meritum-mocks). To samo robi workflow `.github/workflows/email-worker.yml`.

`copy/pl.json` to kopia z meritum-design-system. Odświeżenie: `gh api repos/Meritum-HackNation2026/meritum-design-system/contents/copy/pl.json --jq .content | base64 -d >copy/pl.json`.
