-- ──────────────────────────────────────────────────────────────────────────────
-- CloudCare-K8s database initialisation
-- Runs automatically when the postgres container starts for the first time.
-- ──────────────────────────────────────────────────────────────────────────────

-- 1. Create the two schemas
CREATE SCHEMA IF NOT EXISTS patients;
CREATE SCHEMA IF NOT EXISTS appointments;

-- 2. Create per-service database users
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'patient_svc') THEN
    CREATE USER patient_svc WITH PASSWORD 'patient_pass';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'appt_svc') THEN
    CREATE USER appt_svc WITH PASSWORD 'appt_pass';
  END IF;
END
$$;

-- 3. Grant patient_svc access to patients schema ONLY
GRANT USAGE  ON SCHEMA patients TO patient_svc;
GRANT CREATE ON SCHEMA patients TO patient_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA patients
  GRANT ALL ON TABLES    TO patient_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA patients
  GRANT ALL ON SEQUENCES TO patient_svc;
-- Also grant on any tables that already exist (re-runs are safe)
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA patients TO patient_svc;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA patients TO patient_svc;

-- 4. Grant appt_svc access to appointments schema ONLY
GRANT USAGE  ON SCHEMA appointments TO appt_svc;
GRANT CREATE ON SCHEMA appointments TO appt_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA appointments
  GRANT ALL ON TABLES    TO appt_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA appointments
  GRANT ALL ON SEQUENCES TO appt_svc;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA appointments TO appt_svc;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA appointments TO appt_svc;

-- 5. Explicitly revoke cross-schema access
REVOKE ALL ON SCHEMA appointments FROM patient_svc;
REVOKE ALL ON SCHEMA patients     FROM appt_svc;