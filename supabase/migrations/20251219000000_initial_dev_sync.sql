


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."category_template_enum" AS ENUM (
    'VOTE',
    'TEXT',
    'VIDEO'
);


ALTER TYPE "public"."category_template_enum" OWNER TO "postgres";


CREATE TYPE "public"."tag_enum" AS ENUM (
    'CONTEST',
    'VOTE',
    'TEXT',
    'VOCAL',
    'IMAGE',
    'GAME',
    'VIDEO'
);


ALTER TYPE "public"."tag_enum" OWNER TO "postgres";


CREATE TYPE "public"."widget_type" AS ENUM (
    'COMPONENT',
    'STEP 1',
    'STEP 2',
    'STEP 3',
    'STEP 4',
    'STEP 5'
);


ALTER TYPE "public"."widget_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_complete_schema"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    result jsonb;
BEGIN
    -- Get all enums
    WITH enum_types AS (
        SELECT 
            t.typname as enum_name,
            array_agg(e.enumlabel ORDER BY e.enumsortorder) as enum_values
        FROM pg_type t
        JOIN pg_enum e ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
        GROUP BY t.typname
    )
    SELECT jsonb_build_object(
        'enums',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', enum_name,
                    'values', to_jsonb(enum_values)
                )
            ),
            '[]'::jsonb
        )
    )
    FROM enum_types
    INTO result;

    -- Get all tables with their details
    WITH RECURSIVE 
    columns_info AS (
        SELECT 
            c.oid as table_oid,
            c.relname as table_name,
            a.attname as column_name,
            format_type(a.atttypid, a.atttypmod) as column_type,
            a.attnotnull as notnull,
            pg_get_expr(d.adbin, d.adrelid) as column_default,
            CASE 
                WHEN a.attidentity != '' THEN true
                WHEN pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval%' THEN true
                ELSE false
            END as is_identity,
            EXISTS (
                SELECT 1 FROM pg_constraint con 
                WHERE con.conrelid = c.oid 
                AND con.contype = 'p' 
                AND a.attnum = ANY(con.conkey)
            ) as is_pk
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_attribute a ON a.attrelid = c.oid
        LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE n.nspname = 'public' 
        AND c.relkind = 'r'
        AND a.attnum > 0 
        AND NOT a.attisdropped
    ),
    fk_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', con.conname,
                    'column', col.attname,
                    'foreign_schema', fs.nspname,
                    'foreign_table', ft.relname,
                    'foreign_column', fcol.attname,
                    'on_delete', CASE con.confdeltype
                        WHEN 'a' THEN 'NO ACTION'
                        WHEN 'c' THEN 'CASCADE'
                        WHEN 'r' THEN 'RESTRICT'
                        WHEN 'n' THEN 'SET NULL'
                        WHEN 'd' THEN 'SET DEFAULT'
                        ELSE NULL
                    END
                )
            ) as foreign_keys
        FROM pg_class c
        JOIN pg_constraint con ON con.conrelid = c.oid
        JOIN pg_attribute col ON col.attrelid = con.conrelid AND col.attnum = ANY(con.conkey)
        JOIN pg_class ft ON ft.oid = con.confrelid
        JOIN pg_namespace fs ON fs.oid = ft.relnamespace
        JOIN pg_attribute fcol ON fcol.attrelid = con.confrelid AND fcol.attnum = ANY(con.confkey)
        WHERE con.contype = 'f'
        GROUP BY c.oid
    ),
    index_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', i.relname,
                    'using', am.amname,
                    'columns', (
                        SELECT jsonb_agg(a.attname ORDER BY array_position(ix.indkey, a.attnum))
                        FROM unnest(ix.indkey) WITH ORDINALITY as u(attnum, ord)
                        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
                    )
                )
            ) as indexes
        FROM pg_class c
        JOIN pg_index ix ON ix.indrelid = c.oid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_am am ON am.oid = i.relam
        WHERE NOT ix.indisprimary
        GROUP BY c.oid
    ),
    policy_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', pol.polname,
                    'command', CASE pol.polcmd
                        WHEN 'r' THEN 'SELECT'
                        WHEN 'a' THEN 'INSERT'
                        WHEN 'w' THEN 'UPDATE'
                        WHEN 'd' THEN 'DELETE'
                        WHEN '*' THEN 'ALL'
                    END,
                    'roles', (
                        SELECT string_agg(quote_ident(r.rolname), ', ')
                        FROM pg_roles r
                        WHERE r.oid = ANY(pol.polroles)
                    ),
                    'using', pg_get_expr(pol.polqual, pol.polrelid),
                    'check', pg_get_expr(pol.polwithcheck, pol.polrelid)
                )
            ) as policies
        FROM pg_class c
        JOIN pg_policy pol ON pol.polrelid = c.oid
        GROUP BY c.oid
    ),
    trigger_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', t.tgname,
                    'timing', CASE 
                        WHEN t.tgtype & 2 = 2 THEN 'BEFORE'
                        WHEN t.tgtype & 4 = 4 THEN 'AFTER'
                        WHEN t.tgtype & 64 = 64 THEN 'INSTEAD OF'
                    END,
                    'events', (
                        CASE WHEN t.tgtype & 1 = 1 THEN 'INSERT'
                             WHEN t.tgtype & 8 = 8 THEN 'DELETE'
                             WHEN t.tgtype & 16 = 16 THEN 'UPDATE'
                             WHEN t.tgtype & 32 = 32 THEN 'TRUNCATE'
                        END
                    ),
                    'statement', pg_get_triggerdef(t.oid)
                )
            ) as triggers
        FROM pg_class c
        JOIN pg_trigger t ON t.tgrelid = c.oid
        WHERE NOT t.tgisinternal
        GROUP BY c.oid
    ),
    table_info AS (
        SELECT DISTINCT 
            c.table_oid,
            c.table_name,
            jsonb_agg(
                jsonb_build_object(
                    'name', c.column_name,
                    'type', c.column_type,
                    'notnull', c.notnull,
                    'default', c.column_default,
                    'identity', c.is_identity,
                    'is_pk', c.is_pk
                ) ORDER BY c.column_name
            ) as columns,
            COALESCE(fk.foreign_keys, '[]'::jsonb) as foreign_keys,
            COALESCE(i.indexes, '[]'::jsonb) as indexes,
            COALESCE(p.policies, '[]'::jsonb) as policies,
            COALESCE(t.triggers, '[]'::jsonb) as triggers
        FROM columns_info c
        LEFT JOIN fk_info fk ON fk.table_oid = c.table_oid
        LEFT JOIN index_info i ON i.table_oid = c.table_oid
        LEFT JOIN policy_info p ON p.table_oid = c.table_oid
        LEFT JOIN trigger_info t ON t.table_oid = c.table_oid
        GROUP BY c.table_oid, c.table_name, fk.foreign_keys, i.indexes, p.policies, t.triggers
    )
    SELECT result || jsonb_build_object(
        'tables',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', table_name,
                    'columns', columns,
                    'foreign_keys', foreign_keys,
                    'indexes', indexes,
                    'policies', policies,
                    'triggers', triggers
                )
            ),
            '[]'::jsonb
        )
    )
    FROM table_info
    INTO result;

    -- Get all functions
    WITH function_info AS (
        SELECT 
            p.proname AS name,
            pg_get_functiondef(p.oid) AS definition
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
    )
    SELECT result || jsonb_build_object(
        'functions',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', name,
                    'definition', definition
                )
            ),
            '[]'::jsonb
        )
    )
    FROM function_info
    INTO result;

    RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_complete_schema"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_enum"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$DECLARE
    result jsonb;
BEGIN
    -- Get all enums
    WITH enum_types AS (
        SELECT 
            t.typname as enum_name,
            array_agg(e.enumlabel ORDER BY e.enumsortorder) as enum_values
        FROM pg_type t
        JOIN pg_enum e ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
        GROUP BY t.typname
    )
    SELECT jsonb_build_object(
        'enums',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', enum_name,
                    'values', to_jsonb(enum_values)
                )
            ),
            '[]'::jsonb
        )
    )
    FROM enum_types
    INTO result;

    RETURN result;
END;$$;


ALTER FUNCTION "public"."get_enum"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin_on_entity"("entity_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM app_authorization a
    JOIN app_role r ON r.id = a.role
    WHERE a."user" = auth.uid()
      AND r.name = 'Admin'
      AND a.entity = entity_id
  );
$$;


ALTER FUNCTION "public"."is_admin_on_entity"("entity_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."app_authorization" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entity" "uuid",
    "user" "uuid",
    "role" "uuid",
    "profile" "uuid"
);


ALTER TABLE "public"."app_authorization" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_role" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" character varying,
    "description" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."app_role" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bloc_id" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text",
    "description" "text"
);


ALTER TABLE "public"."bloc_id" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."country" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "name" character varying,
    "language" character varying,
    "flag_image_url" character varying
);


ALTER TABLE "public"."country" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."display_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "bloc_id" "uuid"[] NOT NULL,
    "entities" "uuid"[],
    "status" "uuid",
    "description" "text"
);


ALTER TABLE "public"."display_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."entity" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" character varying,
    "logo_url" character varying,
    "collecting_personnal_information_message" character varying,
    "gpdr_title" character varying,
    "gpdr_text" character varying,
    "gpdr_checkbox" boolean,
    "image_right_title" character varying,
    "Image_right_text" character varying,
    "image_right_checkbox" boolean,
    "thank_you_message" character varying,
    "button_color" character varying,
    "text_color" character varying,
    "background_image_url" character varying,
    "max_character_number" smallint DEFAULT '250'::smallint,
    "opened_date" timestamp with time zone,
    "closed_date" timestamp with time zone,
    "time_zone" character varying,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "modified_at" timestamp with time zone,
    "status_entity" "uuid",
    "type" "uuid",
    "group" "uuid",
    "font-size" smallint DEFAULT '16'::smallint,
    "language" "uuid",
    "sound_time_limit" smallint DEFAULT '180'::smallint,
    "video_time_limit" smallint DEFAULT '180'::smallint,
    "image_list" "text"[]
);


ALTER TABLE "public"."entity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."entity_group" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "status" "uuid" DEFAULT "gen_random_uuid"(),
    "description" "text"
);


ALTER TABLE "public"."entity_group" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."font" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text",
    "font_url" "text",
    "entity" "uuid" DEFAULT "gen_random_uuid"(),
    "weight" smallint DEFAULT '400'::smallint,
    "style" "text" DEFAULT 'normal'::"text"
);


ALTER TABLE "public"."font" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."interaction" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entity" "uuid",
    "title" "text",
    "media" character varying,
    "language" "uuid",
    "template" "uuid",
    "link" character varying,
    "limit_1_participation" boolean,
    "gather_personnal_information" boolean,
    "gpdr_consent" boolean,
    "gpdr_title" "text",
    "gpdr_text" character varying,
    "gpdr_checkbox" boolean DEFAULT false,
    "image_right_consent" boolean,
    "image_right_title" "text",
    "image_right_text" "text",
    "image_right_checkbox" boolean DEFAULT false,
    "home_text" character varying,
    "thank_you_text" character varying,
    "sound_time_limit" smallint,
    "video_time_limit" smallint,
    "text_character_limit" smallint,
    "personnal_information_text" json,
    "show_result" boolean,
    "start_date" timestamp with time zone,
    "end_date" timestamp with time zone,
    "status" "uuid",
    "time_zone" "text",
    "testimonial_text" "text",
    "button_color" "text",
    "text_color" "text",
    "collecting_personnal_information_message" "text",
    "answer_choice" "jsonb"[]
);


ALTER TABLE "public"."interaction" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."moderations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "interaction" "uuid" DEFAULT "gen_random_uuid"(),
    "ip" "text"[]
);


ALTER TABLE "public"."moderations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."participations" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "interaction" "uuid" DEFAULT "gen_random_uuid"(),
    "personal_informations" json,
    "message" json,
    "file_url" "text",
    "transcription" character varying,
    "favorite" boolean,
    "status" "uuid" DEFAULT "gen_random_uuid"(),
    "gpdr_text" character varying,
    "ip" "text",
    "moderate" boolean,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "device_id" "text",
    "image_right_text" "text",
    "image_right_method" "text" DEFAULT 'CheckBox'::"text",
    "gdpr_method" "text" DEFAULT 'CheckBox'::"text",
    "gdpr_at" timestamp with time zone,
    "image_right_at" timestamp with time zone
);


ALTER TABLE "public"."participations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."point_of_distribution" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entity" "uuid" DEFAULT "gen_random_uuid"(),
    "status" "uuid" DEFAULT "gen_random_uuid"(),
    "name" "text",
    "description" "text",
    "link" "text",
    "redirection_canal" "uuid",
    "calendar" "jsonb"[]
);


ALTER TABLE "public"."point_of_distribution" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."status_entity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "description" "text",
    "name" character varying
);


ALTER TABLE "public"."status_entity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."status_generic" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "description" character varying,
    "technical_name" "text" NOT NULL,
    "icon_path" character varying,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order" smallint
);


ALTER TABLE "public"."status_generic" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."style" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "css" "jsonb",
    "entity_uuid" "text"
);


ALTER TABLE "public"."style" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."template" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "name" character varying,
    "description" "text",
    "is_activ" boolean,
    "order" smallint,
    "home_text" boolean DEFAULT false,
    "home_media" boolean DEFAULT false,
    "personnal_information_text" boolean DEFAULT false,
    "show_result" boolean DEFAULT false,
    "status" "uuid",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tags" "public"."tag_enum"[],
    "standard" boolean DEFAULT true NOT NULL,
    "category" "public"."category_template_enum",
    "limit_1_participation" boolean DEFAULT false,
    "gather_personnal_information" boolean DEFAULT false,
    "gpdr_consent" boolean DEFAULT false,
    "image_right_consent" boolean DEFAULT false,
    "thank_you_text" boolean DEFAULT false,
    "video_time_limit" boolean DEFAULT false,
    "sound_time_limit" boolean DEFAULT false,
    "text_character_limit" boolean DEFAULT false,
    "under_description" "text",
    "correct_answer" boolean DEFAULT false,
    "data_collection" boolean DEFAULT false,
    "widget" "uuid",
    "color_parameter" boolean DEFAULT false
);


ALTER TABLE "public"."template" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."template_by_entity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entity" "uuid",
    "template" "uuid",
    "order" smallint
);


ALTER TABLE "public"."template_by_entity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."translation" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "technical_name" "text",
    "fr" "text",
    "en" "text"
);


ALTER TABLE "public"."translation" OWNER TO "postgres";


ALTER TABLE "public"."translation" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."translation_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."type" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "description" character varying,
    "name" character varying
);


ALTER TABLE "public"."type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_info" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_name" character varying,
    "first_name" character varying,
    "country_id" "uuid",
    "profil_picture_url" character varying,
    "modified_at" timestamp with time zone,
    "login" character varying,
    "user_id" "uuid",
    "email" "text",
    "phone" "text",
    "super_admin" boolean
);


ALTER TABLE "public"."user_info" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."widget_component" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text",
    "description" "text",
    "status" "public"."widget_type" DEFAULT 'COMPONENT'::"public"."widget_type" NOT NULL,
    "order" smallint DEFAULT '0'::smallint,
    "action_name" "text"
);


ALTER TABLE "public"."widget_component" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."widget_schema" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "schema" "jsonb",
    "name" "text",
    "description" "text",
    "status" "uuid",
    "dark_mode" boolean DEFAULT false
);


ALTER TABLE "public"."widget_schema" OWNER TO "postgres";


ALTER TABLE ONLY "public"."app_authorization"
    ADD CONSTRAINT "authorization_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bloc_id"
    ADD CONSTRAINT "bloc_id_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."bloc_id"
    ADD CONSTRAINT "bloc_id_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."country"
    ADD CONSTRAINT "country_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."display_profiles"
    ADD CONSTRAINT "display_profiles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."display_profiles"
    ADD CONSTRAINT "display_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."entity_group"
    ADD CONSTRAINT "entity_group_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."entity"
    ADD CONSTRAINT "entity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."font"
    ADD CONSTRAINT "font_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."interaction"
    ADD CONSTRAINT "interaction_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."moderations"
    ADD CONSTRAINT "modérations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."participations"
    ADD CONSTRAINT "participations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."point_of_distribution"
    ADD CONSTRAINT "point_of_distribution_link_key" UNIQUE ("link");



ALTER TABLE ONLY "public"."point_of_distribution"
    ADD CONSTRAINT "point_of_distribution_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_role"
    ADD CONSTRAINT "role_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."status_entity"
    ADD CONSTRAINT "status_entity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."status_generic"
    ADD CONSTRAINT "status_generic_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."style"
    ADD CONSTRAINT "style_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."template_by_entity"
    ADD CONSTRAINT "template_by_entity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."template"
    ADD CONSTRAINT "template_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."translation"
    ADD CONSTRAINT "translation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."translation"
    ADD CONSTRAINT "translation_technical_name_key" UNIQUE ("technical_name");



ALTER TABLE ONLY "public"."type"
    ADD CONSTRAINT "type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_login_key" UNIQUE ("login");



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."widget_component"
    ADD CONSTRAINT "widget_component_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."widget_schema"
    ADD CONSTRAINT "widget_schema_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."widget_schema"
    ADD CONSTRAINT "widget_schema_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_authorization"
    ADD CONSTRAINT "authorization_entity_fkey" FOREIGN KEY ("entity") REFERENCES "public"."entity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_authorization"
    ADD CONSTRAINT "authorization_profile_fkey" FOREIGN KEY ("profile") REFERENCES "public"."display_profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_authorization"
    ADD CONSTRAINT "authorization_role_fkey" FOREIGN KEY ("role") REFERENCES "public"."app_role"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_authorization"
    ADD CONSTRAINT "authorization_user_fkey1" FOREIGN KEY ("user") REFERENCES "public"."user_info"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."display_profiles"
    ADD CONSTRAINT "display_profiles_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id");



ALTER TABLE ONLY "public"."entity"
    ADD CONSTRAINT "entity_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."entity_group"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."entity_group"
    ADD CONSTRAINT "entity_group_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_entity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."entity"
    ADD CONSTRAINT "entity_language_fkey" FOREIGN KEY ("language") REFERENCES "public"."country"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."entity"
    ADD CONSTRAINT "entity_status_entity_fkey" FOREIGN KEY ("status_entity") REFERENCES "public"."status_entity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."entity"
    ADD CONSTRAINT "entity_type_fkey" FOREIGN KEY ("type") REFERENCES "public"."type"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."font"
    ADD CONSTRAINT "font_entity_fkey" FOREIGN KEY ("entity") REFERENCES "public"."entity"("id");



ALTER TABLE ONLY "public"."interaction"
    ADD CONSTRAINT "interaction_entity_fkey" FOREIGN KEY ("entity") REFERENCES "public"."entity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."interaction"
    ADD CONSTRAINT "interaction_language_fkey" FOREIGN KEY ("language") REFERENCES "public"."country"("id");



ALTER TABLE ONLY "public"."interaction"
    ADD CONSTRAINT "interaction_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."interaction"
    ADD CONSTRAINT "interaction_template_fkey" FOREIGN KEY ("template") REFERENCES "public"."template"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."moderations"
    ADD CONSTRAINT "modérations_interaction_fkey" FOREIGN KEY ("interaction") REFERENCES "public"."interaction"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."participations"
    ADD CONSTRAINT "participations_interaction_fkey" FOREIGN KEY ("interaction") REFERENCES "public"."interaction"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."participations"
    ADD CONSTRAINT "participations_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."point_of_distribution"
    ADD CONSTRAINT "point_of_distribution_entity_fkey" FOREIGN KEY ("entity") REFERENCES "public"."entity"("id");



ALTER TABLE ONLY "public"."point_of_distribution"
    ADD CONSTRAINT "point_of_distribution_redirection_canal_fkey" FOREIGN KEY ("redirection_canal") REFERENCES "public"."point_of_distribution"("id");



ALTER TABLE ONLY "public"."point_of_distribution"
    ADD CONSTRAINT "point_of_distribution_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id");



ALTER TABLE ONLY "public"."template_by_entity"
    ADD CONSTRAINT "template_by_entity_entity_fkey" FOREIGN KEY ("entity") REFERENCES "public"."entity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."template_by_entity"
    ADD CONSTRAINT "template_by_entity_template_fkey" FOREIGN KEY ("template") REFERENCES "public"."template"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."template"
    ADD CONSTRAINT "template_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."template"
    ADD CONSTRAINT "template_widget_fkey" FOREIGN KEY ("widget") REFERENCES "public"."widget_schema"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."country"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_info"
    ADD CONSTRAINT "user_info_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."widget_schema"
    ADD CONSTRAINT "widget_schema_status_fkey" FOREIGN KEY ("status") REFERENCES "public"."status_generic"("id");



CREATE POLICY "A modifider" ON "public"."interaction" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All Authenticated USer Can Insert" ON "public"."interaction" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "All Authenticated User Can Select" ON "public"."app_role" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "All Authenticated User Can Select" ON "public"."status_entity" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "All Authenticated User Can Select" ON "public"."status_generic" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "All Authenticated User Can Select" ON "public"."type" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "All Authenticated Users Select" ON "public"."template" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Delete" ON "public"."app_authorization" FOR DELETE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."id" = "auth"."uid"()) AND ("ui"."super_admin" = true)))) OR (EXISTS ( SELECT 1
   FROM "public"."app_authorization" "a"
  WHERE (("a"."user" = "auth"."uid"()) AND ("a"."role" IN ( SELECT "app_role"."id"
           FROM "public"."app_role"
          WHERE (("app_role"."name")::"text" = 'Admin'::"text"))) AND ("a"."entity" = "app_authorization"."entity"))))));



CREATE POLICY "Delete By Super_admin" ON "public"."entity" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))));



CREATE POLICY "Enable read access for all users" ON "public"."translation" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Insert" ON "public"."app_authorization" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Insert By Super Admin" ON "public"."style" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))));



CREATE POLICY "Insert Only Super Admin" ON "public"."entity_group" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))));



CREATE POLICY "Insert Super Admin" ON "public"."entity" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))));



CREATE POLICY "Select" ON "public"."app_authorization" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."id" = "auth"."uid"()) AND ("ui"."super_admin" = true)))) OR (("user" = "auth"."uid"()) AND ("role" IN ( SELECT "app_role"."id"
   FROM "public"."app_role"
  WHERE (("app_role"."name")::"text" = 'User'::"text")))) OR "public"."is_admin_on_entity"("entity")));



CREATE POLICY "Select" ON "public"."country" FOR SELECT USING (true);



CREATE POLICY "Select" ON "public"."style" FOR SELECT USING (true);



CREATE POLICY "Select Only Authenticated USer" ON "public"."entity_group" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Select for super-admin or user with authorization" ON "public"."entity" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))) OR (EXISTS ( SELECT 1
   FROM ("public"."app_authorization" "a"
     JOIN "public"."user_info" "ui" ON (("ui"."id" = "a"."user")))
  WHERE (("ui"."user_id" = "auth"."uid"()) AND ("a"."entity" = "entity"."id"))))));



CREATE POLICY "Super Admin Can Insert" ON "public"."template" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))));



CREATE POLICY "Super Admin Can Update" ON "public"."template" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true))))) WITH CHECK (true);



CREATE POLICY "Update" ON "public"."app_authorization" FOR UPDATE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."id" = "auth"."uid"()) AND ("ui"."super_admin" = true)))) OR (EXISTS ( SELECT 1
   FROM "public"."app_authorization" "a"
  WHERE (("a"."user" = "auth"."uid"()) AND ("a"."role" IN ( SELECT "app_role"."id"
           FROM "public"."app_role"
          WHERE (("app_role"."name")::"text" = 'Admin'::"text"))) AND ("a"."entity" = "app_authorization"."entity")))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."id" = "auth"."uid"()) AND ("ui"."super_admin" = true)))) OR (EXISTS ( SELECT 1
   FROM "public"."app_authorization" "a"
  WHERE (("a"."user" = "auth"."uid"()) AND ("a"."role" IN ( SELECT "app_role"."id"
           FROM "public"."app_role"
          WHERE (("app_role"."name")::"text" = 'Admin'::"text"))) AND ("a"."entity" = "app_authorization"."entity"))))));



CREATE POLICY "Update by authenticated user super_admin or with authorization" ON "public"."entity" FOR UPDATE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true)))) OR (EXISTS ( SELECT 1
   FROM ("public"."app_authorization" "a"
     JOIN "public"."user_info" "ui" ON (("ui"."id" = "a"."user")))
  WHERE (("ui"."user_id" = "auth"."uid"()) AND ("a"."entity" = "entity"."id")))))) WITH CHECK (true);



CREATE POLICY "Update only super admin" ON "public"."entity_group" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_info" "ui"
  WHERE (("ui"."user_id" = "auth"."uid"()) AND (COALESCE("ui"."super_admin", false) = true))))) WITH CHECK (true);



CREATE POLICY "a modif" ON "public"."interaction" FOR DELETE USING (true);



ALTER TABLE "public"."app_role" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."country" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."entity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."entity_group" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."interaction" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."moderations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "select" ON "public"."interaction" FOR SELECT USING (true);



ALTER TABLE "public"."status_entity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."status_generic" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."style" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."translation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."type" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."participations";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."get_complete_schema"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_complete_schema"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_complete_schema"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_enum"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_enum"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_enum"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin_on_entity"("entity_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin_on_entity"("entity_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin_on_entity"("entity_id" "uuid") TO "service_role";


















GRANT ALL ON TABLE "public"."app_authorization" TO "anon";
GRANT ALL ON TABLE "public"."app_authorization" TO "authenticated";
GRANT ALL ON TABLE "public"."app_authorization" TO "service_role";



GRANT ALL ON TABLE "public"."app_role" TO "anon";
GRANT ALL ON TABLE "public"."app_role" TO "authenticated";
GRANT ALL ON TABLE "public"."app_role" TO "service_role";



GRANT ALL ON TABLE "public"."bloc_id" TO "anon";
GRANT ALL ON TABLE "public"."bloc_id" TO "authenticated";
GRANT ALL ON TABLE "public"."bloc_id" TO "service_role";



GRANT ALL ON TABLE "public"."country" TO "anon";
GRANT ALL ON TABLE "public"."country" TO "authenticated";
GRANT ALL ON TABLE "public"."country" TO "service_role";



GRANT ALL ON TABLE "public"."display_profiles" TO "anon";
GRANT ALL ON TABLE "public"."display_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."display_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."entity" TO "anon";
GRANT ALL ON TABLE "public"."entity" TO "authenticated";
GRANT ALL ON TABLE "public"."entity" TO "service_role";



GRANT ALL ON TABLE "public"."entity_group" TO "anon";
GRANT ALL ON TABLE "public"."entity_group" TO "authenticated";
GRANT ALL ON TABLE "public"."entity_group" TO "service_role";



GRANT ALL ON TABLE "public"."font" TO "anon";
GRANT ALL ON TABLE "public"."font" TO "authenticated";
GRANT ALL ON TABLE "public"."font" TO "service_role";



GRANT ALL ON TABLE "public"."interaction" TO "anon";
GRANT ALL ON TABLE "public"."interaction" TO "authenticated";
GRANT ALL ON TABLE "public"."interaction" TO "service_role";



GRANT ALL ON TABLE "public"."moderations" TO "anon";
GRANT ALL ON TABLE "public"."moderations" TO "authenticated";
GRANT ALL ON TABLE "public"."moderations" TO "service_role";



GRANT ALL ON TABLE "public"."participations" TO "anon";
GRANT ALL ON TABLE "public"."participations" TO "authenticated";
GRANT ALL ON TABLE "public"."participations" TO "service_role";



GRANT ALL ON TABLE "public"."point_of_distribution" TO "anon";
GRANT ALL ON TABLE "public"."point_of_distribution" TO "authenticated";
GRANT ALL ON TABLE "public"."point_of_distribution" TO "service_role";



GRANT ALL ON TABLE "public"."status_entity" TO "anon";
GRANT ALL ON TABLE "public"."status_entity" TO "authenticated";
GRANT ALL ON TABLE "public"."status_entity" TO "service_role";



GRANT ALL ON TABLE "public"."status_generic" TO "anon";
GRANT ALL ON TABLE "public"."status_generic" TO "authenticated";
GRANT ALL ON TABLE "public"."status_generic" TO "service_role";



GRANT ALL ON TABLE "public"."style" TO "anon";
GRANT ALL ON TABLE "public"."style" TO "authenticated";
GRANT ALL ON TABLE "public"."style" TO "service_role";



GRANT ALL ON TABLE "public"."template" TO "anon";
GRANT ALL ON TABLE "public"."template" TO "authenticated";
GRANT ALL ON TABLE "public"."template" TO "service_role";



GRANT ALL ON TABLE "public"."template_by_entity" TO "anon";
GRANT ALL ON TABLE "public"."template_by_entity" TO "authenticated";
GRANT ALL ON TABLE "public"."template_by_entity" TO "service_role";



GRANT ALL ON TABLE "public"."translation" TO "anon";
GRANT ALL ON TABLE "public"."translation" TO "authenticated";
GRANT ALL ON TABLE "public"."translation" TO "service_role";



GRANT ALL ON SEQUENCE "public"."translation_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."translation_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."translation_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."type" TO "anon";
GRANT ALL ON TABLE "public"."type" TO "authenticated";
GRANT ALL ON TABLE "public"."type" TO "service_role";



GRANT ALL ON TABLE "public"."user_info" TO "anon";
GRANT ALL ON TABLE "public"."user_info" TO "authenticated";
GRANT ALL ON TABLE "public"."user_info" TO "service_role";



GRANT ALL ON TABLE "public"."widget_component" TO "anon";
GRANT ALL ON TABLE "public"."widget_component" TO "authenticated";
GRANT ALL ON TABLE "public"."widget_component" TO "service_role";



GRANT ALL ON TABLE "public"."widget_schema" TO "anon";
GRANT ALL ON TABLE "public"."widget_schema" TO "authenticated";
GRANT ALL ON TABLE "public"."widget_schema" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































