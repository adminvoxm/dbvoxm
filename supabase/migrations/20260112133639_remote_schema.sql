create extension if not exists "pg_cron" with schema "pg_catalog";

alter table "public"."entity" add column "participation_retention_period" smallint;

alter table "public"."participations" alter column "moderate" set default false;

alter table "public"."template" drop column "category";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_participations_to_clean()
 RETURNS TABLE(id uuid, file_url text)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    p.id, 
    p.file_url -- On récupère l'URL pour pouvoir supprimer le fichier
  FROM participations p
  JOIN interaction i ON p.interaction = i.id
  JOIN entity e ON i.entity = e.id
  WHERE 
    -- Votre logique de date dynamique
    p.created_at < (now() - (e.participation_retention_period || ' days')::interval)
    -- On ne prend que ceux qui ont un fichier OU qui ne sont pas encore 'delete'
    AND (p.file_url IS NOT NULL OR p.status != (SELECT id FROM status_generic WHERE technical_name = 'delete'))
  LIMIT 1000; -- Sécurité pour ne pas tout faire exploser d'un coup
END;
$function$
;




