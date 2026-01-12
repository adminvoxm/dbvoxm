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


