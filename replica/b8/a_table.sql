-- Publicly readable copies of canonical reference images, one per
-- canonical asset. A video provider fetches them by URL; the canonical
-- originals stay in the private bucket.
create table if not exists public.video_reference_images (
    asset_id uuid primary key references public.asset_registry(id) on delete restrict,
    bucket text not null default 'public-refs',
    object_path text not null,
    is_active boolean not null default true,
    set_by text not null,
    note text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint video_reference_images_path_check check (
        btrim(object_path) <> '' and object_path !~ '^/' and object_path !~ '[[:space:]?#]'
        and btrim(bucket) <> '' and bucket !~ '[/[:space:]?#]')
);
