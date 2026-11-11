-- =====================================================================
--  Gym App — Customer Database (PostgreSQL 14+)
--  Covers: members, memberships & billing, check-ins, class bookings,
--          workout history, body measurements, goals, staff notes.
--  Conventions:
--    * UUID primary keys (safe to expose in APIs / URLs)
--    * money stored as integer minor units (agorot / cents) + currency
--    * all timestamps are timestamptz (stored UTC)
--    * soft delete on members via deleted_at
--    * status columns are text + CHECK (easy to extend, no enum migrations)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- no-overlap constraints
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid()

CREATE SCHEMA IF NOT EXISTS gym;
SET search_path = gym, public;

-- ---------------------------------------------------------------------
-- Helper: keep updated_at fresh
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- =====================================================================
-- 1. LOCATIONS & STAFF
-- =====================================================================
CREATE TABLE branches (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  address     text,
  city        text,
  phone       text,
  timezone    text NOT NULL DEFAULT 'Asia/Jerusalem',
  capacity    int  CHECK (capacity > 0),          -- max people on the floor
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staff (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id   uuid REFERENCES branches(id) ON DELETE SET NULL,
  first_name  text NOT NULL,
  last_name   text NOT NULL,
  email       citext UNIQUE,
  phone       text,
  role        text NOT NULL DEFAULT 'trainer'
              CHECK (role IN ('trainer','front_desk','manager','admin')),
  bio         text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 2. MEMBERS (customers)
-- =====================================================================
CREATE TABLE members (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_number     bigint GENERATED ALWAYS AS IDENTITY UNIQUE, -- human-friendly #
  email             citext NOT NULL,
  phone             text,
  password_hash     text,              -- NULL if auth handled by external provider
  auth_provider     text,              -- e.g. 'google', 'apple', 'firebase'
  auth_provider_uid text,
  first_name        text NOT NULL,
  last_name         text NOT NULL,
  date_of_birth     date CHECK (date_of_birth > '1900-01-01'),
  gender            text CHECK (gender IN ('male','female','other','prefer_not_to_say')),
  photo_url         text,
  home_branch_id    uuid REFERENCES branches(id) ON DELETE SET NULL,
  access_card_code  text UNIQUE,       -- RFID / QR value used at the door
  status            text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('lead','active','inactive','suspended','banned')),
  marketing_opt_in  boolean NOT NULL DEFAULT false,
  waiver_signed_at  timestamptz,       -- liability waiver / health declaration
  health_notes      text,              -- injuries, conditions (sensitive!)
  preferred_language text DEFAULT 'he',
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,       -- soft delete
  CONSTRAINT members_auth_provider_uid_uk UNIQUE (auth_provider, auth_provider_uid)
);
-- email unique only among non-deleted members (allows re-signup after deletion)
CREATE UNIQUE INDEX members_email_live_uk ON members (email) WHERE deleted_at IS NULL;
CREATE INDEX members_phone_idx       ON members (phone);
CREATE INDEX members_home_branch_idx ON members (home_branch_id);
CREATE INDEX members_name_idx        ON members (lower(last_name), lower(first_name));

CREATE TABLE emergency_contacts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  full_name    text NOT NULL,
  relationship text,
  phone        text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX emergency_contacts_member_idx ON emergency_contacts (member_id);

-- Internal notes staff write about a member (front desk, trainers)
CREATE TABLE member_notes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id   uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  staff_id    uuid REFERENCES staff(id) ON DELETE SET NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX member_notes_member_idx ON member_notes (member_id, created_at DESC);

-- =====================================================================
-- 3. PLANS, MEMBERSHIPS, FREEZES, PAYMENTS
-- =====================================================================
CREATE TABLE membership_plans (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL UNIQUE,         -- "Monthly", "Annual", "10-Visit Card"
  description      text,
  price_minor      int  NOT NULL CHECK (price_minor >= 0),  -- 19900 = 199.00
  currency         char(3) NOT NULL DEFAULT 'ILS',
  billing_period   text NOT NULL
                   CHECK (billing_period IN ('one_time','weekly','monthly','quarterly','yearly')),
  duration_days    int CHECK (duration_days > 0), -- NULL = open-ended recurring
  visit_limit      int CHECK (visit_limit > 0),   -- NULL = unlimited (punch cards use this)
  includes_classes boolean NOT NULL DEFAULT true,
  all_branches     boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,  -- hide from sale without deleting
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id          uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  plan_id            uuid NOT NULL REFERENCES membership_plans(id),
  status             text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('pending','active','frozen','cancelled','expired')),
  start_date         date NOT NULL,
  end_date           date,                    -- NULL = runs until cancelled
  auto_renew         boolean NOT NULL DEFAULT true,
  price_minor        int NOT NULL CHECK (price_minor >= 0), -- price locked at signup
  currency           char(3) NOT NULL DEFAULT 'ILS',
  visits_remaining   int CHECK (visits_remaining >= 0),     -- for punch cards
  cancelled_at       timestamptz,
  cancel_reason      text,
  sold_by_staff_id   uuid REFERENCES staff(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date IS NULL OR end_date >= start_date),
  -- a member can't hold two overlapping live memberships
  CONSTRAINT memberships_no_overlap EXCLUDE USING gist (
    member_id WITH =,
    daterange(start_date, COALESCE(end_date, 'infinity'::date), '[]') WITH &&
  ) WHERE (status IN ('pending','active','frozen'))
);
CREATE INDEX memberships_member_idx ON memberships (member_id, start_date DESC);
CREATE INDEX memberships_status_idx ON memberships (status, end_date);

CREATE TABLE membership_freezes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  membership_id  uuid NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
  start_date     date NOT NULL,
  end_date       date NOT NULL,
  reason         text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date),
  CONSTRAINT freezes_no_overlap EXCLUDE USING gist (
    membership_id WITH =, daterange(start_date, end_date, '[]') WITH &&
  )
);

CREATE TABLE payments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id          uuid NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
  membership_id      uuid REFERENCES memberships(id) ON DELETE SET NULL,
  amount_minor       int NOT NULL,             -- negative = refund
  currency           char(3) NOT NULL DEFAULT 'ILS',
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','succeeded','failed','refunded','partially_refunded')),
  method             text CHECK (method IN ('card','cash','bank_transfer','bit','paybox','apple_pay','google_pay','other')),
  provider           text,                     -- 'stripe', 'tranzila', 'cardcom'...
  provider_ref       text,                     -- external transaction id (never store card numbers!)
  description        text,
  paid_at            timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_provider_ref_uk UNIQUE (provider, provider_ref)  -- idempotent webhooks
);
CREATE INDEX payments_member_idx ON payments (member_id, created_at DESC);
CREATE INDEX payments_membership_idx ON payments (membership_id);

-- =====================================================================
-- 4. VISIT HISTORY (check-ins)
-- =====================================================================
CREATE TABLE check_ins (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id       uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES branches(id),
  membership_id   uuid REFERENCES memberships(id) ON DELETE SET NULL,
  checked_in_at   timestamptz NOT NULL DEFAULT now(),
  checked_out_at  timestamptz,
  method          text NOT NULL DEFAULT 'qr'
                  CHECK (method IN ('qr','card','app','manual','face')),
  CHECK (checked_out_at IS NULL OR checked_out_at >= checked_in_at)
);
CREATE INDEX check_ins_member_idx ON check_ins (member_id, checked_in_at DESC);
CREATE INDEX check_ins_branch_time_idx ON check_ins (branch_id, checked_in_at DESC);
-- fast "who is in the gym right now"
CREATE INDEX check_ins_open_idx ON check_ins (branch_id) WHERE checked_out_at IS NULL;

-- =====================================================================
-- 5. CLASSES & BOOKINGS
-- =====================================================================
CREATE TABLE class_types (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL UNIQUE,  -- "Spinning", "Yoga", "HIIT"
  description      text,
  default_minutes  int NOT NULL DEFAULT 60 CHECK (default_minutes > 0),
  intensity        text CHECK (intensity IN ('low','medium','high')),
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE class_sessions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  class_type_id  uuid NOT NULL REFERENCES class_types(id),
  branch_id      uuid NOT NULL REFERENCES branches(id),
  trainer_id     uuid REFERENCES staff(id) ON DELETE SET NULL,
  room           text,
  starts_at      timestamptz NOT NULL,
  ends_at        timestamptz NOT NULL,
  capacity       int NOT NULL CHECK (capacity > 0),
  status         text NOT NULL DEFAULT 'scheduled'
                 CHECK (status IN ('scheduled','cancelled','completed')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX class_sessions_branch_time_idx ON class_sessions (branch_id, starts_at);
CREATE INDEX class_sessions_trainer_idx ON class_sessions (trainer_id, starts_at);

CREATE TABLE class_bookings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  class_session_id  uuid NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
  member_id         uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  status            text NOT NULL DEFAULT 'booked'
                    CHECK (status IN ('booked','waitlisted','cancelled','attended','no_show')),
  waitlist_position int,
  booked_at         timestamptz NOT NULL DEFAULT now(),
  cancelled_at      timestamptz,
  UNIQUE (class_session_id, member_id)
);
CREATE INDEX class_bookings_member_idx ON class_bookings (member_id, booked_at DESC);

-- Auto-waitlist: if the class is full, a new booking becomes 'waitlisted'.
CREATE OR REPLACE FUNCTION class_booking_capacity() RETURNS trigger AS $$
DECLARE
  cap   int;
  taken int;
BEGIN
  IF NEW.status <> 'booked' THEN RETURN NEW; END IF;
  -- lock the session row so two simultaneous bookings can't both take the last spot
  SELECT capacity INTO cap FROM class_sessions WHERE id = NEW.class_session_id FOR UPDATE;
  SELECT count(*) INTO taken FROM class_bookings
   WHERE class_session_id = NEW.class_session_id
     AND status IN ('booked','attended')
     AND id <> NEW.id;
  IF taken >= cap THEN
    NEW.status := 'waitlisted';
    SELECT COALESCE(max(waitlist_position), 0) + 1 INTO NEW.waitlist_position
      FROM class_bookings
     WHERE class_session_id = NEW.class_session_id AND status = 'waitlisted';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER class_bookings_capacity_trg
  BEFORE INSERT ON class_bookings
  FOR EACH ROW EXECUTE FUNCTION class_booking_capacity();

-- When a booked member cancels, promote the first person on the waitlist.
CREATE OR REPLACE FUNCTION class_booking_promote_waitlist() RETURNS trigger AS $$
DECLARE
  next_id uuid;
BEGIN
  IF OLD.status = 'booked' AND NEW.status = 'cancelled' THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
    PERFORM 1 FROM class_sessions WHERE id = NEW.class_session_id FOR UPDATE;
    SELECT id INTO next_id FROM class_bookings
     WHERE class_session_id = NEW.class_session_id AND status = 'waitlisted'
     ORDER BY waitlist_position, booked_at LIMIT 1;
    IF next_id IS NOT NULL THEN
      UPDATE class_bookings SET status = 'booked', waitlist_position = NULL WHERE id = next_id;
      UPDATE class_bookings SET waitlist_position = waitlist_position - 1
       WHERE class_session_id = NEW.class_session_id AND status = 'waitlisted';
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER class_bookings_promote_trg
  BEFORE UPDATE OF status ON class_bookings
  FOR EACH ROW EXECUTE FUNCTION class_booking_promote_waitlist();

-- =====================================================================
-- 6. WORKOUT HISTORY
-- =====================================================================
CREATE TABLE exercises (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE,     -- "Bench Press"
  muscle_group  text,                     -- "chest", "legs", ...
  equipment     text,                     -- "barbell", "machine", "bodyweight"
  category      text NOT NULL DEFAULT 'strength'
                CHECK (category IN ('strength','cardio','mobility','other')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- One gym session the member logged (or a trainer logged for them)
CREATE TABLE workouts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id        uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  check_in_id      uuid REFERENCES check_ins(id) ON DELETE SET NULL,
  trainer_id       uuid REFERENCES staff(id) ON DELETE SET NULL,  -- personal training
  title            text,                  -- "Leg day"
  started_at       timestamptz NOT NULL DEFAULT now(),
  ended_at         timestamptz,
  calories_burned  int CHECK (calories_burned >= 0),
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX workouts_member_idx ON workouts (member_id, started_at DESC);

CREATE TABLE workout_sets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workout_id        uuid NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  exercise_id       uuid NOT NULL REFERENCES exercises(id),
  set_number        int NOT NULL CHECK (set_number > 0),
  reps              int CHECK (reps >= 0),
  weight_kg         numeric(6,2) CHECK (weight_kg >= 0),
  duration_seconds  int CHECK (duration_seconds >= 0),   -- cardio / planks
  distance_m        numeric(9,2) CHECK (distance_m >= 0),
  rpe               numeric(3,1) CHECK (rpe BETWEEN 1 AND 10), -- perceived effort
  UNIQUE (workout_id, exercise_id, set_number)
);
CREATE INDEX workout_sets_exercise_idx ON workout_sets (exercise_id);

-- =====================================================================
-- 7. PROGRESS: BODY MEASUREMENTS & GOALS
-- =====================================================================
CREATE TABLE body_measurements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id      uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  measured_at    timestamptz NOT NULL DEFAULT now(),
  weight_kg      numeric(5,2) CHECK (weight_kg > 0),
  height_cm      numeric(5,1) CHECK (height_cm > 0),
  body_fat_pct   numeric(4,1) CHECK (body_fat_pct BETWEEN 0 AND 100),
  muscle_mass_kg numeric(5,2) CHECK (muscle_mass_kg > 0),
  waist_cm       numeric(5,1),
  chest_cm       numeric(5,1),
  hips_cm        numeric(5,1),
  resting_hr     int CHECK (resting_hr BETWEEN 20 AND 250),
  recorded_by    uuid REFERENCES staff(id) ON DELETE SET NULL,  -- NULL = self-reported
  notes          text
);
CREATE INDEX body_measurements_member_idx ON body_measurements (member_id, measured_at DESC);

CREATE TABLE member_goals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id     uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  goal_type     text NOT NULL
                CHECK (goal_type IN ('lose_weight','gain_muscle','strength','endurance','visits_per_week','custom')),
  description   text,
  target_value  numeric(8,2),
  unit          text,                     -- 'kg', 'visits', 'km'...
  exercise_id   uuid REFERENCES exercises(id),  -- e.g. "bench 100kg"
  target_date   date,
  status        text NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','achieved','abandoned')),
  achieved_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX member_goals_member_idx ON member_goals (member_id, status);

-- =====================================================================
-- 8. updated_at triggers
-- =====================================================================
CREATE TRIGGER branches_updated_at         BEFORE UPDATE ON branches         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER staff_updated_at            BEFORE UPDATE ON staff            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER members_updated_at          BEFORE UPDATE ON members          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER membership_plans_updated_at BEFORE UPDATE ON membership_plans FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER memberships_updated_at      BEFORE UPDATE ON memberships      FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- 9. VIEWS for the backend
-- =====================================================================

-- Each member's current membership (one row per member, NULL plan if none)
CREATE OR REPLACE VIEW v_member_current_membership AS
SELECT m.id AS member_id,
       m.first_name, m.last_name, m.email, m.status AS member_status,
       ms.id AS membership_id, p.name AS plan_name, ms.status AS membership_status,
       ms.start_date, ms.end_date, ms.visits_remaining, ms.auto_renew,
       COALESCE(ms.status = 'active'
        AND ms.start_date <= current_date
        AND (ms.end_date IS NULL OR ms.end_date >= current_date)
        AND (ms.visits_remaining IS NULL OR ms.visits_remaining > 0), false) AS can_enter
FROM members m
LEFT JOIN LATERAL (
  SELECT * FROM memberships x
  WHERE x.member_id = m.id AND x.status IN ('active','frozen','pending')
  ORDER BY x.start_date DESC LIMIT 1
) ms ON true
LEFT JOIN membership_plans p ON p.id = ms.plan_id
WHERE m.deleted_at IS NULL;

-- Visit stats per member (for profile screen / churn reports)
CREATE OR REPLACE VIEW v_member_visit_stats AS
SELECT m.id AS member_id,
       count(c.id)                                                          AS total_visits,
       count(c.id) FILTER (WHERE c.checked_in_at >= now() - interval '30 days') AS visits_last_30d,
       max(c.checked_in_at)                                                 AS last_visit_at,
       round(avg(EXTRACT(EPOCH FROM (c.checked_out_at - c.checked_in_at)) / 60)
             FILTER (WHERE c.checked_out_at IS NOT NULL))::int              AS avg_visit_minutes
FROM members m
LEFT JOIN check_ins c ON c.member_id = m.id
WHERE m.deleted_at IS NULL
GROUP BY m.id;

-- Who is in each branch right now
CREATE OR REPLACE VIEW v_branch_occupancy AS
SELECT b.id AS branch_id, b.name, b.capacity,
       count(c.id) AS people_inside
FROM branches b
LEFT JOIN check_ins c
  ON c.branch_id = b.id AND c.checked_out_at IS NULL
 AND c.checked_in_at >= now() - interval '12 hours'   -- ignore forgotten check-outs
GROUP BY b.id;

-- Personal records: heaviest weight per member per exercise
CREATE OR REPLACE VIEW v_personal_records AS
SELECT w.member_id, s.exercise_id, e.name AS exercise_name,
       max(s.weight_kg) AS best_weight_kg,
       max(s.reps)      AS best_reps
FROM workout_sets s
JOIN workouts  w ON w.id = s.workout_id
JOIN exercises e ON e.id = s.exercise_id
GROUP BY w.member_id, s.exercise_id, e.name;

-- =====================================================================
-- 10. Descriptions (shown in pgAdmin, DBeaver, Supabase table editor)
-- =====================================================================
COMMENT ON SCHEMA gym IS 'Gym app customer database. Guide: docs/DATABASE.md';
COMMENT ON TABLE branches           IS 'Gym locations. Members have a home branch; check-ins and classes happen at a branch.';
COMMENT ON TABLE staff              IS 'People who work at the gym: trainers, front desk, managers, admins.';
COMMENT ON TABLE members            IS 'One row per customer. Soft-deleted via deleted_at; email unique among live members.';
COMMENT ON TABLE emergency_contacts IS 'Who to call if something happens to a member.';
COMMENT ON TABLE member_notes       IS 'Internal staff notes about a member. Never shown in the member app.';
COMMENT ON TABLE membership_plans   IS 'Plans the gym sells (Monthly, Annual, 10-visit card). Prices in minor units.';
COMMENT ON TABLE memberships        IS 'A plan a member bought, with dates and locked-in price. No two live memberships may overlap.';
COMMENT ON TABLE membership_freezes IS 'Periods a membership was paused. Freezes on one membership may not overlap.';
COMMENT ON TABLE payments           IS 'Money received or refunded (negative amount). (provider, provider_ref) is unique for idempotent webhooks.';
COMMENT ON TABLE check_ins          IS 'Visit history: one row per entry to a branch, with optional check-out time.';
COMMENT ON TABLE class_types        IS 'Kinds of classes offered (Spinning, Yoga, HIIT).';
COMMENT ON TABLE class_sessions     IS 'A scheduled class at a time, branch and room, with a capacity.';
COMMENT ON TABLE class_bookings     IS 'A member''s spot in a class. Full classes auto-waitlist; cancelling promotes the waitlist.';
COMMENT ON TABLE exercises          IS 'Catalog of exercises used in workout logs and goals.';
COMMENT ON TABLE workouts           IS 'One logged training session by a member.';
COMMENT ON TABLE workout_sets       IS 'Each set in a workout: reps and weight, or time and distance for cardio.';
COMMENT ON TABLE body_measurements  IS 'Weight, body fat and other measurements over time. Health data: restrict access.';
COMMENT ON TABLE member_goals       IS 'Targets a member set, e.g. bench 100 kg or 3 visits a week.';
COMMENT ON COLUMN members.health_notes IS 'Sensitive health data. Expose only to the member and their trainer.';
COMMENT ON COLUMN membership_plans.price_minor IS 'Price in minor units: 24900 = 249.00 ILS.';
COMMENT ON VIEW v_member_current_membership IS 'Current plan per member and can_enter (true/false) for the door scanner.';
COMMENT ON VIEW v_member_visit_stats IS 'Total visits, last 30 days, last visit, average visit length.';
COMMENT ON VIEW v_branch_occupancy IS 'People inside each branch now (ignores check-ins older than 12h without check-out).';
COMMENT ON VIEW v_personal_records IS 'Best weight and reps per member per exercise.';
