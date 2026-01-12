drop function if exists "public"."get_participations_to_clean"();

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_participations_to_clean()
 RETURNS TABLE(target_id uuid, target_file_url text)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    p.id, 
    p.file_url 
  FROM participations p
  JOIN interaction i ON p.interaction = i.id
  JOIN entity e ON i.entity = e.id
  WHERE 
    -- Logique de date
    p.created_at < (now() - (e.participation_retention_period || ' days')::interval)
    -- On cible ceux qui ont un fichier OU qui ne sont pas encore 'delete'
    AND (p.file_url IS NOT NULL OR p.status != (SELECT s.id FROM status_generic s WHERE s.technical_name = 'delete'))
  LIMIT 1000;
END;
$function$
;
CREATE TRIGGER enforce_bucket_name_length_trigger BEFORE INSERT OR UPDATE OF name ON storage.buckets FOR EACH ROW EXECUTE FUNCTION storage.enforce_bucket_name_length();
CREATE TRIGGER objects_delete_delete_prefix AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();
CREATE TRIGGER objects_insert_create_prefix BEFORE INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.objects_insert_prefix_trigger();
CREATE TRIGGER objects_update_create_prefix BEFORE UPDATE ON storage.objects FOR EACH ROW WHEN (((new.name <> old.name) OR (new.bucket_id <> old.bucket_id))) EXECUTE FUNCTION storage.objects_update_prefix_trigger();
CREATE TRIGGER update_objects_updated_at BEFORE UPDATE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.update_updated_at_column();
CREATE TRIGGER prefixes_create_hierarchy BEFORE INSERT ON storage.prefixes FOR EACH ROW WHEN ((pg_trigger_depth() < 1)) EXECUTE FUNCTION storage.prefixes_insert_trigger();
CREATE TRIGGER prefixes_delete_hierarchy AFTER DELETE ON storage.prefixes FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();


