alter table "public"."entity" drop constraint if exists "entity_old_ref_key";

drop index if exists "public"."entity_old_ref_key";

alter table "public"."widget_schema" add column "entity" uuid;

alter table "public"."widget_schema" add constraint "widget_schema_entity_fkey" FOREIGN KEY (entity) REFERENCES public.entity(id) not valid;

alter table "public"."widget_schema" validate constraint "widget_schema_entity_fkey";


