alter table "public"."bloc_id" enable row level security;

alter table "public"."font" enable row level security;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.user_info
    WHERE user_id = auth.uid()
    AND super_admin = true
  );
END;
$function$
;


  create policy "Seuls les super-admins ont un accès total"
  on "public"."bloc_id"
  as permissive
  for all
  to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());



  create policy "Lecture publique pour tous"
  on "public"."font"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "Modifications réservées aux super-admins"
  on "public"."font"
  as permissive
  for all
  to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());



