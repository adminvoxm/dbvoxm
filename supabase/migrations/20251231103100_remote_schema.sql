alter table "public"."entity" add column "old_ref" text;

CREATE UNIQUE INDEX entity_old_ref_key ON public.entity USING btree (old_ref);

alter table "public"."entity" add constraint "entity_old_ref_key" UNIQUE using index "entity_old_ref_key";


  create policy "Authenticated User 22ox_1"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using ((bucket_id = 'app'::text));



  create policy "Authenticated User 22ox_3"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using ((bucket_id = 'app'::text));


DROP POLICY IF EXISTS "Update 22ox_0" ON "storage"."objects";
  create policy "Update 22ox_0"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using ((bucket_id = 'app'::text));



  create policy "insert 22ox_0"
  on "storage"."objects"
  as permissive
  for insert
  to public
with check ((bucket_id = 'app'::text));


CREATE TRIGGER enforce_bucket_name_length_trigger BEFORE INSERT OR UPDATE OF name ON storage.buckets FOR EACH ROW EXECUTE FUNCTION storage.enforce_bucket_name_length();

CREATE TRIGGER objects_delete_delete_prefix AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();

CREATE TRIGGER objects_insert_create_prefix BEFORE INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.objects_insert_prefix_trigger();

CREATE TRIGGER objects_update_create_prefix BEFORE UPDATE ON storage.objects FOR EACH ROW WHEN (((new.name <> old.name) OR (new.bucket_id <> old.bucket_id))) EXECUTE FUNCTION storage.objects_update_prefix_trigger();

CREATE TRIGGER update_objects_updated_at BEFORE UPDATE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.update_updated_at_column();

CREATE TRIGGER prefixes_create_hierarchy BEFORE INSERT ON storage.prefixes FOR EACH ROW WHEN ((pg_trigger_depth() < 1)) EXECUTE FUNCTION storage.prefixes_insert_trigger();

CREATE TRIGGER prefixes_delete_hierarchy AFTER DELETE ON storage.prefixes FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();


