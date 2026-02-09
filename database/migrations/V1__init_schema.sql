-- Flyway migration V1: Core schema for airport passenger service platform
-- Conventions:
--  - snake_case, plural table names
--  - UUID primary keys
--  - created_at/updated_at timestamptz
--  - *_by UUID audit columns where applicable
--  - jsonb for flexible payloads
--
-- Notes:
--  - This migration is intended to be executed by Flyway from Spring Boot services.
--  - "Idempotent" in Flyway is achieved by versioning; do not re-run the same version with changes.
--  - We use CREATE EXTENSION IF NOT EXISTS for required extensions.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Generic trigger to keep updated_at fresh
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =========================
-- Admin / RBAC
-- =========================
CREATE TABLE IF NOT EXISTS admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email varchar(255) NOT NULL,
  password_hash varchar(255) NOT NULL,
  full_name varchar(200),
  is_active boolean NOT NULL DEFAULT true,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_admins_email UNIQUE (email)
);

CREATE TABLE IF NOT EXISTS roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(100) NOT NULL,
  description varchar(255),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_roles_name UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(150) NOT NULL,
  description varchar(255),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_permissions_name UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS admin_roles (
  admin_id uuid NOT NULL,
  role_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  PRIMARY KEY (admin_id, role_id),
  CONSTRAINT fk_admin_roles_admin FOREIGN KEY (admin_id) REFERENCES admins(id) ON DELETE CASCADE,
  CONSTRAINT fk_admin_roles_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS role_permissions (
  role_id uuid NOT NULL,
  permission_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  PRIMARY KEY (role_id, permission_id),
  CONSTRAINT fk_role_permissions_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE,
  CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions(id) ON DELETE CASCADE
);

-- =========================
-- Passengers / KYC / Aadhaar OTP
-- =========================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'kyc_status') THEN
    CREATE TYPE kyc_status AS ENUM ('NOT_STARTED', 'PENDING', 'VERIFIED', 'REJECTED');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS passengers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_e164 varchar(20),
  email varchar(255),
  full_name varchar(200),
  date_of_birth date,
  aadhaar_last4 varchar(4),
  kyc_status kyc_status NOT NULL DEFAULT 'NOT_STARTED',
  kyc_verified_at timestamptz,
  digilocker_user_id varchar(100),
  digilocker_document_refs jsonb, -- e.g. {"aadhaar":"ref","pan":"ref"}
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_passengers_phone UNIQUE (phone_e164),
  CONSTRAINT uq_passengers_email UNIQUE (email)
);

CREATE TABLE IF NOT EXISTS aadhaar_otp_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid,
  aadhaar_ref varchar(100),
  txn_id varchar(120) NOT NULL,
  otp_sent_to varchar(50),
  status varchar(30) NOT NULL, -- e.g. SENT, VERIFIED, FAILED, EXPIRED
  attempts int NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  verified_at timestamptz,
  error_code varchar(50),
  error_message varchar(500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_aadhaar_otp_sessions_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE SET NULL,
  CONSTRAINT uq_aadhaar_otp_sessions_txn UNIQUE (txn_id)
);

-- =========================
-- Chatbot
-- =========================
CREATE TABLE IF NOT EXISTS chatbot_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid,
  language_code varchar(10) NOT NULL DEFAULT 'en',
  channel varchar(30) NOT NULL DEFAULT 'text', -- text/voice/web
  status varchar(30) NOT NULL DEFAULT 'OPEN', -- OPEN/CLOSED
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_chatbot_conversations_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS chatbot_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL,
  sender varchar(20) NOT NULL, -- USER/BOT/SYSTEM
  message_type varchar(30) NOT NULL DEFAULT 'text', -- text/voice/event
  content text,
  payload jsonb, -- LLM/voice metadata, translations, etc.
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_chatbot_messages_conversation FOREIGN KEY (conversation_id) REFERENCES chatbot_conversations(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chatbot_messages_conversation_created_at
  ON chatbot_messages (conversation_id, created_at);

-- =========================
-- Flights / Flight status cache
-- =========================
CREATE TABLE IF NOT EXISTS flights (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  airline_code varchar(10) NOT NULL,
  flight_number varchar(10) NOT NULL,
  flight_date date NOT NULL,
  origin_airport varchar(10),
  destination_airport varchar(10),
  scheduled_departure timestamptz,
  scheduled_arrival timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_flights_unique UNIQUE (airline_code, flight_number, flight_date)
);

CREATE TABLE IF NOT EXISTS flight_status_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flight_id uuid NOT NULL,
  status varchar(40) NOT NULL, -- ON_TIME/DELAYED/CANCELLED/BOARDING etc.
  gate varchar(20),
  belt varchar(20),
  terminal varchar(20),
  raw_payload jsonb,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_flight_status_cache_flight FOREIGN KEY (flight_id) REFERENCES flights(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_flight_status_cache_flight_expires
  ON flight_status_cache (flight_id, expires_at);

-- =========================
-- Facilities Catalog + Bookings
-- =========================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'facility_type') THEN
    CREATE TYPE facility_type AS ENUM ('PARKING', 'LOUNGE', 'HOTEL', 'RESTAURANT', 'SERVICE');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS facilities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_type facility_type NOT NULL,
  code varchar(60) NOT NULL,
  name varchar(200) NOT NULL,
  description text,
  location_text varchar(255),
  is_active boolean NOT NULL DEFAULT true,
  price_base numeric(10,2),
  currency_code varchar(3) NOT NULL DEFAULT 'INR',
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT uq_facilities_type_code UNIQUE (facility_type, code)
);

CREATE INDEX IF NOT EXISTS idx_facilities_type_active
  ON facilities (facility_type, is_active);

-- Parent booking table for common fields
CREATE TABLE IF NOT EXISTS bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid NOT NULL,
  facility_id uuid NOT NULL,
  booking_type facility_type NOT NULL,
  status varchar(30) NOT NULL DEFAULT 'PENDING', -- PENDING/CONFIRMED/CANCELLED/COMPLETED
  reference_code varchar(40) NOT NULL,
  start_at timestamptz,
  end_at timestamptz,
  amount numeric(10,2),
  currency_code varchar(3) NOT NULL DEFAULT 'INR',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_bookings_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE CASCADE,
  CONSTRAINT fk_bookings_facility FOREIGN KEY (facility_id) REFERENCES facilities(id) ON DELETE RESTRICT,
  CONSTRAINT uq_bookings_reference UNIQUE (reference_code)
);

CREATE INDEX IF NOT EXISTS idx_bookings_passenger_created_at
  ON bookings (passenger_id, created_at);

-- Specialized booking tables (1:1 with bookings.id)
CREATE TABLE IF NOT EXISTS parking_bookings (
  booking_id uuid PRIMARY KEY,
  vehicle_number varchar(20) NOT NULL,
  slot_code varchar(30),
  entry_time timestamptz,
  exit_time timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_parking_bookings_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS lounge_bookings (
  booking_id uuid PRIMARY KEY,
  lounge_pass_count int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_lounge_bookings_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS hotel_bookings (
  booking_id uuid PRIMARY KEY,
  guests_count int NOT NULL DEFAULT 1,
  room_type varchar(50),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_hotel_bookings_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE
);

-- =========================
-- Feedback / Grievances
-- =========================
CREATE TABLE IF NOT EXISTS feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid,
  facility_id uuid,
  rating int,
  title varchar(200),
  message text NOT NULL,
  status varchar(30) NOT NULL DEFAULT 'OPEN', -- OPEN/IN_REVIEW/RESOLVED/CLOSED
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_feedback_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE SET NULL,
  CONSTRAINT fk_feedback_facility FOREIGN KEY (facility_id) REFERENCES facilities(id) ON DELETE SET NULL,
  CONSTRAINT chk_feedback_rating CHECK (rating IS NULL OR (rating >= 1 AND rating <= 5))
);

CREATE TABLE IF NOT EXISTS grievances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid,
  booking_id uuid,
  category varchar(80),
  subject varchar(200) NOT NULL,
  description text NOT NULL,
  priority varchar(20) NOT NULL DEFAULT 'NORMAL', -- LOW/NORMAL/HIGH/URGENT
  status varchar(30) NOT NULL DEFAULT 'OPEN', -- OPEN/ASSIGNED/RESOLVED/CLOSED
  assigned_admin_id uuid,
  resolution text,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_grievances_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE SET NULL,
  CONSTRAINT fk_grievances_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE SET NULL,
  CONSTRAINT fk_grievances_assigned_admin FOREIGN KEY (assigned_admin_id) REFERENCES admins(id) ON DELETE SET NULL
);

-- =========================
-- Notifications (optional)
-- =========================
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id uuid,
  title varchar(200) NOT NULL,
  body text NOT NULL,
  channel varchar(30) NOT NULL DEFAULT 'PUSH', -- PUSH/SMS/EMAIL/WHATSAPP
  status varchar(30) NOT NULL DEFAULT 'PENDING', -- PENDING/SENT/FAILED
  payload jsonb,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_by uuid,
  CONSTRAINT fk_notifications_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_notifications_passenger_created_at
  ON notifications (passenger_id, created_at);

-- =========================
-- Audit Events (generic)
-- =========================
CREATE TABLE IF NOT EXISTS audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_type varchar(30) NOT NULL, -- ADMIN/PASSENGER/SYSTEM
  actor_id uuid,
  action varchar(100) NOT NULL,
  entity_table varchar(80),
  entity_id uuid,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- =========================
-- updated_at triggers
-- =========================
DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT table_name
    FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'updated_at'
    GROUP BY table_name
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_updated_at ON %I', t.table_name);
    EXECUTE format(
      'CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
      t.table_name
    );
  END LOOP;
END $$;
