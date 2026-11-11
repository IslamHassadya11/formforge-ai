-- Sample data for local development / UI work. Safe to re-run on an empty DB.
SET search_path = gym, public;

INSERT INTO branches (id, name, address, city, capacity) VALUES
 ('00000000-0000-0000-0000-0000000000b1', 'Downtown', '12 Herzl St', 'Haifa', 120),
 ('00000000-0000-0000-0000-0000000000b2', 'Carmel',   '5 Moriah Ave', 'Haifa', 80);

INSERT INTO staff (id, branch_id, first_name, last_name, email, role) VALUES
 ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 'Noa',  'Levi',   'noa@gym.test',  'trainer'),
 ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 'Omer', 'Cohen',  'omer@gym.test', 'front_desk'),
 ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b2', 'Dana', 'Mizrahi','dana@gym.test', 'manager');

INSERT INTO membership_plans (id, name, price_minor, billing_period, duration_days, visit_limit, includes_classes, all_branches) VALUES
 ('00000000-0000-0000-0000-0000000000d1', 'Monthly',        24900, 'monthly',  30,  NULL, true,  false),
 ('00000000-0000-0000-0000-0000000000d2', 'Annual',        229900, 'yearly',   365, NULL, true,  true),
 ('00000000-0000-0000-0000-0000000000d3', '10-Visit Card',  45000, 'one_time', 180, 10,   false, false);

INSERT INTO members (id, email, phone, first_name, last_name, date_of_birth, gender, home_branch_id, access_card_code, waiver_signed_at) VALUES
 ('00000000-0000-0000-0000-0000000000f1', 'yossi@example.com', '050-1111111', 'Yossi', 'Ben-David', '1992-04-10', 'male',   '00000000-0000-0000-0000-0000000000b1', 'QR-1001', now() - interval '90 days'),
 ('00000000-0000-0000-0000-0000000000f2', 'maya@example.com',  '052-2222222', 'Maya',  'Azulay',    '1998-09-21', 'female', '00000000-0000-0000-0000-0000000000b1', 'QR-1002', now() - interval '40 days'),
 ('00000000-0000-0000-0000-0000000000f3', 'amir@example.com',  '054-3333333', 'Amir',  'Haddad',    '1985-01-03', 'male',   '00000000-0000-0000-0000-0000000000b2', 'QR-1003', now() - interval '10 days');

INSERT INTO emergency_contacts (member_id, full_name, relationship, phone) VALUES
 ('00000000-0000-0000-0000-0000000000f1', 'Rina Ben-David', 'spouse', '050-9999999');

INSERT INTO memberships (id, member_id, plan_id, status, start_date, end_date, price_minor, visits_remaining, sold_by_staff_id) VALUES
 ('00000000-0000-0000-0000-00000000ab01', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d2', 'active', current_date - 90, current_date + 275, 229900, NULL, '00000000-0000-0000-0000-0000000000a2'),
 ('00000000-0000-0000-0000-00000000ab02', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000d1', 'active', current_date - 10, current_date + 20,  24900,  NULL, '00000000-0000-0000-0000-0000000000a2'),
 ('00000000-0000-0000-0000-00000000ab03', '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000d3', 'active', current_date - 10, current_date + 170, 45000,  8,    NULL);

INSERT INTO payments (member_id, membership_id, amount_minor, status, method, provider, provider_ref, paid_at) VALUES
 ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000ab01', 229900, 'succeeded', 'card', 'stripe', 'pi_test_001', now() - interval '90 days'),
 ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000ab02',  24900, 'succeeded', 'bit',  'bit',    'bit_test_002', now() - interval '10 days'),
 ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000ab03',  45000, 'succeeded', 'cash', NULL,     NULL,          now() - interval '10 days');

INSERT INTO check_ins (id, member_id, branch_id, membership_id, checked_in_at, checked_out_at, method) VALUES
 ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000ab01', now() - interval '2 days 2 hours', now() - interval '2 days 45 minutes', 'qr'),
 ('00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000ab01', now() - interval '1 hour', NULL, 'app'),
 ('00000000-0000-0000-0000-00000000c003', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000ab02', now() - interval '5 days', now() - interval '5 days' + interval '70 minutes', 'card'),
 ('00000000-0000-0000-0000-00000000c004', '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000ab03', now() - interval '3 days', now() - interval '3 days' + interval '50 minutes', 'qr');

INSERT INTO class_types (id, name, default_minutes, intensity) VALUES
 ('00000000-0000-0000-0000-0000000000c1', 'Spinning', 45, 'high'),
 ('00000000-0000-0000-0000-0000000000c2', 'Yoga',     60, 'low');

INSERT INTO class_sessions (id, class_type_id, branch_id, trainer_id, room, starts_at, ends_at, capacity) VALUES
 ('00000000-0000-0000-0000-00000000cd01', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'Studio A',
  date_trunc('day', now()) + interval '1 day 18 hours', date_trunc('day', now()) + interval '1 day 18 hours 45 minutes', 2);

INSERT INTO exercises (id, name, muscle_group, equipment, category) VALUES
 ('00000000-0000-0000-0000-0000000000e1', 'Bench Press', 'chest', 'barbell',  'strength'),
 ('00000000-0000-0000-0000-0000000000e2', 'Back Squat',  'legs',  'barbell',  'strength'),
 ('00000000-0000-0000-0000-0000000000e3', 'Treadmill',   'cardio','machine',  'cardio');

INSERT INTO workouts (id, member_id, check_in_id, title, started_at, ended_at) VALUES
 ('00000000-0000-0000-0000-00000000ef01', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000c001', 'Push day',
  now() - interval '2 days 2 hours', now() - interval '2 days 50 minutes');

INSERT INTO workout_sets (workout_id, exercise_id, set_number, reps, weight_kg, duration_seconds, distance_m) VALUES
 ('00000000-0000-0000-0000-00000000ef01', '00000000-0000-0000-0000-0000000000e1', 1, 10, 60,   NULL, NULL),
 ('00000000-0000-0000-0000-00000000ef01', '00000000-0000-0000-0000-0000000000e1', 2,  8, 70,   NULL, NULL),
 ('00000000-0000-0000-0000-00000000ef01', '00000000-0000-0000-0000-0000000000e1', 3,  5, 80,   NULL, NULL),
 ('00000000-0000-0000-0000-00000000ef01', '00000000-0000-0000-0000-0000000000e3', 1, NULL, NULL, 900, 2500);

INSERT INTO body_measurements (member_id, measured_at, weight_kg, height_cm, body_fat_pct, recorded_by) VALUES
 ('00000000-0000-0000-0000-0000000000f1', now() - interval '90 days', 88.5, 180, 24.0, '00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000f1', now() - interval '2 days',  84.2, 180, 21.5, '00000000-0000-0000-0000-0000000000a1');

INSERT INTO member_goals (member_id, goal_type, description, target_value, unit, exercise_id, target_date) VALUES
 ('00000000-0000-0000-0000-0000000000f1', 'strength',    'Bench 100kg', 100, 'kg', '00000000-0000-0000-0000-0000000000e1', current_date + 120),
 ('00000000-0000-0000-0000-0000000000f2', 'visits_per_week', 'Train 3x a week', 3, 'visits', NULL, NULL);
