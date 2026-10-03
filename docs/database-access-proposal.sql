-- REVIEW PROPOSAL ONLY. Not applied. Requires per-app catalog/ACL, restore,
-- secure credential handoff and coordinator cutover approval described in database-runtime-access.md.
-- Adoption must have completed before this script. This script creates NOLOGIN roles;
-- enabling approved migration/runtime logins and private credential injection is an owner-only step.
-- This removes PUBLIC CONNECT/TEMP only on the selected app database after consumer review.
-- Rights inherited in other databases remain a separate reviewed gate.
\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN IF current_database() <> 'daily_checklist' THEN RAISE EXCEPTION 'Wrong database'; END IF; END $$;
DO $$ BEGIN IF to_regclass('public.app_schema_versions') IS NULL THEN RAISE EXCEPTION 'Adopt schema first'; END IF; END $$;
CREATE ROLE ritual_cue_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE ritual_cue_migrator NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE ritual_cue_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ritual_cue_owner TO ritual_cue_migrator WITH INHERIT FALSE;
-- Add explicit CONNECT grants for any additional catalog-verified legitimate consumers before approval.
REVOKE ALL ON DATABASE daily_checklist FROM PUBLIC;
GRANT CONNECT ON DATABASE daily_checklist TO ritual_cue_migrator, ritual_cue_runtime;
ALTER SCHEMA public OWNER TO ritual_cue_owner;
-- Before approval, enumerate and preserve any additional legitimate schema users.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ritual_cue_runtime;
ALTER TABLE public.daily_app_state OWNER TO ritual_cue_owner;
REVOKE ALL ON public.daily_app_state FROM PUBLIC;
GRANT SELECT, UPDATE ON public.daily_app_state TO ritual_cue_runtime;
ALTER TABLE public.app_schema_versions OWNER TO ritual_cue_owner;
REVOKE ALL ON public.app_schema_versions FROM PUBLIC;
GRANT SELECT ON public.app_schema_versions TO ritual_cue_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE ritual_cue_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- New tables/sequences get no default runtime grants; each migration grants its reviewed objects.
-- Database/extension ownership and shared admin credentials are intentionally untouched.
COMMIT;
