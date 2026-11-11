# Gym App Database — How It Works

A plain-language guide to the customer database: what it stores, what it checks on its own, and what the backend still has to do.

## What this database is

This database is the gym app's memory. Everything the app needs to remember about a customer lives here: who they are, what plan they paid for, every time they walked in, which classes they booked, what they lifted, and how their weight changed over time.

Think of it as a set of connected tables, like spreadsheets that point at each other. The members table has one row per person. The check-ins table has one row per visit, and each row says which member it belongs to. That link is what lets the app show "Yossi visited 12 times this month".

The UI never talks to the database directly. The app screens ask the backend, the backend reads and writes the database, and sends the answer back.

It runs on PostgreSQL (version 14 or newer) and was tested on PostgreSQL 16. All tables live in a schema called `gym`.

## The big picture

The database has 18 tables: the member in the middle and six groups around it, each connected back to the member. That's why the app can show a full customer profile from one member ID.

```mermaid
flowchart TB
  billing["<b>Plans and billing</b><br/>What they bought and paid<br/><i>membership_plans, memberships,<br/>membership_freezes, payments</i>"]
  visits["<b>Visit history</b><br/>Every door scan, in and out<br/><i>check_ins</i>"]
  gym["<b>Gym and staff</b><br/>Branches and who works there<br/><i>branches, staff</i>"]
  member(["<b>Member</b><br/>Name, contact, door card code, status<br/><i>members, emergency_contacts, member_notes</i>"])
  classes["<b>Classes</b><br/>Schedule, bookings, waitlist<br/><i>class_types, class_sessions, class_bookings</i>"]
  workouts["<b>Workouts</b><br/>What they lifted or ran<br/><i>exercises, workouts, workout_sets</i>"]
  progress["<b>Progress</b><br/>Body changes and targets<br/><i>body_measurements, member_goals</i>"]
  billing --- member
  visits --- member
  gym --- member
  member --- classes
  member --- workouts
  member --- progress
```

Plans, visits, classes, workouts and progress all belong to one member. Branches and staff are shared by everyone: a member has a home branch, and trainers run classes and record measurements.

## A member's journey, step by step

The easiest way to understand the database is to follow one customer, Maya, from signing up to leaving. Each step shows which table gets a new row.

1. **Maya signs up.** A row is added to `members` with her name, email, phone and home branch. She gets a long hidden ID for the app and a short member number (like #2) for the front desk. Her emergency contact goes in `emergency_contacts`.
2. **She buys the Monthly plan.** The plans the gym sells live in `membership_plans`. Buying one creates a row in `memberships` that says which plan, the start and end dates, and the price she paid. The price is copied in, so if the gym raises prices later, her deal does not change.
3. **She pays.** A row goes into `payments` with the amount, the method (card, cash, Bit, PayBox and so on), and the payment company's transaction ID. Card numbers are never stored.
4. **She scans her QR at the door.** The app checks whether she is allowed in, then adds a row to `check_ins` with the time and the branch. When she leaves, the check-out time is filled in. This is her visit history.
5. **She books a Spinning class.** The class schedule is in `class_sessions`. Her booking is a row in `class_bookings`. If the class is full, she is put on the waitlist automatically.
6. **She logs her workout.** A row in `workouts` holds the session ("Leg day"), and each set she did goes in `workout_sets`: exercise, reps, weight, or time and distance for cardio.
7. **A trainer measures her.** Weight, body fat, waist and so on go in `body_measurements`, one row per measurement, so the app can draw a progress chart.
8. **She sets a goal.** "Train 3 times a week" or "Bench 100 kg" goes in `member_goals`.
9. **She freezes her plan for a trip.** A row in `membership_freezes` records the freeze dates.
10. **She leaves the gym.** Her membership is marked cancelled. If she asks to delete her account, her member row is marked as deleted, not erased. Her history stays for the gym's records, and her email can be used again to sign up later.

## Rules the database enforces on its own

Some mistakes are blocked by the database itself, so the backend can't save bad data even by accident. When a rule is broken, the database refuses the save and returns an error the backend can turn into a friendly message.

| What happens | What the database does | Message the app could show |
| --- | --- | --- |
| Someone signs up with an email that's already used | Refuses. `Maya@x.com` and `maya@x.com` count as the same email | "This email already has an account" |
| A member gets a second plan that overlaps the one they have | Refuses | "You already have an active plan for these dates" |
| Two freezes on the same plan overlap | Refuses | "These dates overlap an existing freeze" |
| A member books a class that is full | Saves the booking as **waitlisted** and gives a place in line (1, 2, 3…) | "Class is full, you're #2 on the waitlist" |
| A booked member cancels | Marks the booking cancelled, records the time, and moves the first waitlisted person into the class | Notify the person who got in |
| The payment company sends the same payment twice | Refuses the duplicate, so nobody is charged twice in our records | Nothing, just ignore it |
| A value that isn't allowed, like status "vip" | Refuses. Each status field has a fixed list of allowed values | Usually a bug, log it |
| Any row in a main table is edited | Updates its "last changed" time automatically | — |

Numbers are checked too: a weight can't be negative, body fat must be 0 to 100%, an end date can't come before its start date, and a check-out can't happen before the check-in.

## What the backend still has to do

The database stores things and blocks bad data, but it doesn't run on a clock or make business decisions. These jobs belong to the backend:

- [ ] **Count down punch cards.** When a member on a 10-visit card checks in, lower `visits_remaining` by one.
- [ ] **Expire old plans.** Once a day, mark memberships whose end date has passed as `expired`.
- [ ] **Renew plans.** For plans with auto-renew on, create the next membership and charge the payment.
- [ ] **Handle freezes.** Decide whether a freeze pushes the end date later. That's a gym policy, so it's left to the backend.
- [ ] **Check members out.** Fill in the check-out time when they leave. If people forget, the "who's in the gym now" count ignores visits older than 12 hours anyway.
- [ ] **Close out classes.** After a class, mark each booking `attended` or `no_show`.
- [ ] **Send notifications.** Tell a member when they move off the waitlist, when their plan is about to end, and so on.
- [ ] **Hash passwords.** If we store passwords, the backend hashes them with bcrypt or argon2 before saving. Plain passwords never go in the database.

## Ready-made answers for common screens

A view is a saved question. Instead of joining five tables every time, the backend asks the view and gets the answer ready. There are four:

| View | The question it answers | Screen that uses it |
| --- | --- | --- |
| `v_member_current_membership` | What plan does this member have right now, and can they come in? Gives a simple true/false called `can_enter` | Door scanner, profile screen |
| `v_member_visit_stats` | How many times have they visited in total and in the last 30 days, when was their last visit, and how long do they usually stay? | Profile screen, "members at risk of leaving" report |
| `v_branch_occupancy` | How many people are inside each branch right now? | "How busy is the gym" screen |
| `v_personal_records` | What's the heaviest weight and most reps this member ever did on each exercise? | Progress screen |

A member can enter when their plan is active, today falls between its start and end dates, and (for punch cards) they still have visits left. Anyone without a plan gets `false`.

Example SQL for every common screen is in the [README](../README.md#common-queries).

## How to set it up and connect

The database comes as two files. `schema.sql` builds all the tables, rules and views. `seed.sql` fills them with sample people and visits so the UI has something to show while we build.

1. **Get a Postgres database.** The easiest option for a team is a free shared one on [Supabase](https://supabase.com) or [Neon](https://neon.tech). Each developer can also run their own copy with Docker.
2. **Run the files once.** Paste `schema.sql` into the provider's SQL editor and run it, then do the same with `seed.sql`. From a terminal: `psql "<connection string>" -f schema.sql`.
3. **Share the connection string with the backend team.** It looks like `postgresql://user:password@host:5432/dbname`. It goes in an environment variable called `DATABASE_URL`, never in the code or in git.
4. **Point the backend at the `gym` schema.** Either write `gym.members`, or run `SET search_path = gym, public` once when connecting.

To check it worked, ask the database who can enter: `select first_name, plan_name, can_enter from gym.v_member_current_membership`. You should see Yossi, Maya and Amir.

**Changing it later:** once real data is in, don't re-run `schema.sql`. Write a small change file instead (for example `002_add_referral_code.sql`) and run the change files in order.

### How data is written

| Thing | How it's stored | Example |
| --- | --- | --- |
| IDs | Long random codes (UUIDs), safe to put in links | `3f2a9c1e-5b7d-…` |
| Member number | Short counting number for the front desk | #1042 |
| Money | Whole agorot, never decimals | `24900` means ₪249.00 |
| Currency | Three letters, default ILS | `ILS` |
| Dates and times | Stored in UTC, shown in local time by the app | `2026-11-11 14:06+00` |
| Email | Not case-sensitive | `Maya@x.com` = `maya@x.com` |

## Privacy and sensitive data

Some of what we store is personal health information, so it needs more care than the rest.

| Sensitive data | Where it lives | Who should see it |
| --- | --- | --- |
| Injuries and health conditions | `members.health_notes` | The member and their trainer |
| Date of birth | `members.date_of_birth` | The member and staff who need it |
| Weight, body fat, measurements | `body_measurements` | The member and their trainer |
| Emergency contact | `emergency_contacts` | Front desk and managers |
| Staff notes about a member | `member_notes` | Staff only, never the member app |

The backend should only return these to people who need them and should never write them to logs. Card numbers are never stored at all, only the payment company's transaction ID. Under Israel's Privacy Protection Law, a customer database like this may need to be registered and protected with access controls, so it's worth checking before launch.

## Glossary

| Word | Meaning |
| --- | --- |
| Table | A list of rows with the same columns, like one sheet in a spreadsheet |
| Row | One item in a table: one member, one visit, one payment |
| ID | The unique code that identifies a row. Other tables use it to point at that row |
| Link (foreign key) | A column that points at a row in another table, like `check_ins.member_id` pointing at a member |
| Schema | A folder for tables. Ours is called `gym` |
| View | A saved question the database answers on demand |
| Trigger | A small rule that runs automatically when a row is saved, like moving someone off the waitlist |
| Soft delete | Marking a row as deleted with a date instead of erasing it |
| Seed data | Fake sample data for testing |
| Connection string | The address and password the backend uses to reach the database |
| Status | A column with a fixed list of allowed words, like `active`, `frozen`, `cancelled` |
