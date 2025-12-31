-- 1. Ajout de la colonne et contraintes de manière sécurisée
ALTER TABLE "public"."entity" ADD COLUMN IF NOT EXISTS "old_ref" text;

-- Index : On le supprime s'il existe déjà pour le recréer proprement
DROP INDEX IF EXISTS entity_old_ref_key;
CREATE UNIQUE INDEX entity_old_ref_key ON public.entity USING btree (old_ref);

-- Contrainte : On essaye de l'ajouter, si elle existe on ignore l'erreur (via un bloc DO car pas de "IF NOT EXISTS" simple pour les contraintes)
DO $$
BEGIN
  BEGIN
    alter table "public"."entity" add constraint "entity_old_ref_key" UNIQUE using index "entity_old_ref_key";
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;


-- 2. POLITIQUES DE SÉCURITÉ (POLICIES)
-- On supprime l'ancienne version avant de créer la nouvelle pour éviter les conflits

-- Policy: Select
DROP POLICY IF EXISTS "Authenticated User 22ox_1" ON "storage"."objects";
CREATE POLICY "Authenticated User 22ox_1"
  ON "storage"."objects"
  AS permissive
  FOR SELECT
  TO authenticated
  USING ((bucket_id = 'app'::text));

-- Policy: Delete
DROP POLICY IF EXISTS "Authenticated User 22ox_3" ON "storage"."objects";
CREATE POLICY "Authenticated User 22ox_3"
  ON "storage"."objects"
  AS permissive
  FOR DELETE
  TO authenticated
  USING ((bucket_id = 'app'::text));

-- Policy: Update (J'ai remplacé ton bloc DO par un DROP/CREATE plus propre et standard)
DROP POLICY IF EXISTS "Update 22ox_0" ON "storage"."objects";
CREATE POLICY "Update 22ox_0"
  ON "storage"."objects"
  AS permissive
  FOR UPDATE
  TO authenticated
  USING ((bucket_id = 'app'::text));

-- Policy: Insert (Celle qui plantait tout à l'heure)
DROP POLICY IF EXISTS "insert 22ox_0" ON "storage"."objects";
CREATE POLICY "insert 22ox_0"
  ON "storage"."objects"
  AS permissive
  FOR INSERT
  TO public
  WITH CHECK ((bucket_id = 'app'::text));


-- 3. TRIGGERS
-- Même logique : on supprime avant de recréer

DROP TRIGGER IF EXISTS enforce_bucket_name_length_trigger ON storage.buckets;
CREATE TRIGGER enforce_bucket_name_length_trigger BEFORE INSERT OR UPDATE OF name ON storage.buckets FOR EACH ROW EXECUTE FUNCTION storage.enforce_bucket_name_length();

DROP TRIGGER IF EXISTS objects_delete_delete_prefix ON storage.objects;
CREATE TRIGGER objects_delete_delete_prefix AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();

DROP TRIGGER IF EXISTS objects_insert_create_prefix ON storage.objects;
CREATE TRIGGER objects_insert_create_prefix BEFORE INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.objects_insert_prefix_trigger();

DROP TRIGGER IF EXISTS objects_update_create_prefix ON storage.objects;
CREATE TRIGGER objects_update_create_prefix BEFORE UPDATE ON storage.objects FOR EACH ROW WHEN (((new.name <> old.name) OR (new.bucket_id <> old.bucket_id))) EXECUTE FUNCTION storage.objects_update_prefix_trigger();

DROP TRIGGER IF EXISTS update_objects_updated_at ON storage.objects;
CREATE TRIGGER update_objects_updated_at BEFORE UPDATE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.update_updated_at_column();

DROP TRIGGER IF EXISTS prefixes_create_hierarchy ON storage.prefixes;
CREATE TRIGGER prefixes_create_hierarchy BEFORE INSERT ON storage.prefixes FOR EACH ROW WHEN ((pg_trigger_depth() < 1)) EXECUTE FUNCTION storage.prefixes_insert_trigger();

DROP TRIGGER IF EXISTS prefixes_delete_hierarchy ON storage.prefixes;
CREATE TRIGGER prefixes_delete_hierarchy AFTER DELETE ON storage.prefixes FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();