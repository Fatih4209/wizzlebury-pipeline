# WIZZLEBURY / M417 üretim hattı

Make senaryolarının çağırdığı Supabase (Postgres) katmanı: adım motoru, iki evet kuralı,
film kuralları, ses / video / montaj / paketleme fonksiyonları ve test takımı.

Anahtar, şifre ya da token bu depoda **yoktur** ve olmamalıdır.

## Klasörler

- `migrations/` — canlı veritabanına sırayla uygulanan dosyalar (002 … 011). Her biri tek işlem,
  yeniden çalıştırılabilir. 004 ve 011 bağlayıcıyla, diğerleri SQL Editor'den uygulandı.
- `src/` — tam şemanın parçaları (`p01 … p10`, `film_*.sql`), `gen_film.py` (009 hâlinden 010
  değişikliklerini yamalar) ve derleme betikleri. `build.sh` tam şemayı, `build_010.sh` 010'u üretir.
- `test/` — PostgREST gibi çağıran test sürücüsü ve takımlar (toplam 684 kontrol).
  `sig.sql`: canlı yol ile tam şemanın aynı olduğunu doğrulayan imza sorgusu.
- `replica/` — testlerin kullandığı yerel kopya: canlı şemanın dışa aktarımı ve yükleyiciler.

## Notlar

- Betiklerdeki mutlak yollar yazıldıkları çalışma alanına aittir; başka yerde çalıştırmadan önce
  `S=` satırları düzeltilmelidir.
- SQL Editor'e yapıştırılan dosyalar CRLF taşır; canlı ile karşılaştırırken
  `replace(pg_get_functiondef(...), chr(13), '')` kullanılır.
- Talimat metinleri (TOPIC, SCRIPT, SHOT_PACKAGE, PREQC, DIRECTOR, FINAL_QC) veritabanında
  `public.step_prompts` tablosundadır; DIRECTOR v2 yalnızca canlıdadır, `src/film_prompts.sql`e işlenecek.
- Durum ve kararlar: claude.ai projesindeki `claude/*.md` belgeleri.
