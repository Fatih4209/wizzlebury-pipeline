-- =====================================================================
-- M417 / WIZZLEBURY - 002 uygulandiktan SONRA calistirilacak ayarlar
--
-- Once 002_pipeline_layers.sql calistirilir. Bu dosya ondan sonra,
-- adim adim calistirilir. BUYUK HARFLE yazili yerleri degistir.
-- Buraya API anahtari ya da sifre YAZILMAZ.
-- =====================================================================

-- ADIM 1 - Kontrol: 002 kuruldu mu?
-- Sonucta "pipeline_enabled": false ve "generation_enabled": false gorunmeli.
select public.pipeline_overview();


-- ADIM 2 - Telegram sohbet numarasi (bildirimlerin gidecegi sohbet).
-- Yalnizca rakamlardan olusur, ornek: 123456789
select public.set_text_setting('notify_chat_id', 'TELEGRAM_SOHBET_NUMARASI');


-- ADIM 3 - Supabase depolama adresi.
-- PROJE_KODU: Supabase > Project Settings > General > "Project ID".
select public.set_text_setting('storage_base_url', 'https://PROJE_KODU.supabase.co/storage/v1');


-- ADIM 4 - Bu ayin harcama tavani (dolar). Bu bir odeme degil, ust sinirdir:
-- sistem bu tutarin uzerine cikamaz. Ornekte 10 dolar yazili.
-- Her ayin basinda yeniden calistirilir.
select public.open_monthly_budget(10, 'FATIH');


-- ADIM 5 - Ana salter. Bunu EN SON ac. Kapatmak icin true yerine false yaz.
select public.set_pipeline_enabled(true);


-- ADIM 6 - Son kontrol: "pipeline_enabled": true ve aylik butce gorunmeli.
-- "generation_enabled" false KALMALI (video uretimi ayri acilacak).
select public.pipeline_overview();
