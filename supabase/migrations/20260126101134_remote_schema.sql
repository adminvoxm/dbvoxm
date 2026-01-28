create type "public"."file_type" as enum ('AUDIO', 'VIDEO', 'IMAGE');

alter table "public"."participations" add column "file_type" public.file_type;

alter table "public"."style" disable row level security;


