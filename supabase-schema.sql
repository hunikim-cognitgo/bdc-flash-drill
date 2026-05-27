-- BDC Flash Drill — Supabase Schema v1
-- Run in: Supabase Dashboard → SQL Editor → New Query → paste → Run

-- ============================================================
-- DEV RESET — uncomment if you need to wipe and recreate
-- ============================================================
-- drop table if exists answers cascade;
-- drop table if exists drill_sessions cascade;
-- drop table if exists rep_progress cascade;
-- drop table if exists reps cascade;
-- drop function if exists create_rep(text, text, text);
-- drop function if exists verify_pin(text, text);
-- drop function if exists get_rep(uuid);

-- ============================================================
-- Extensions
-- Supabase pre-installs pgcrypto in the `extensions` schema, so we
-- reference its functions as `extensions.crypt(...)` / `extensions.gen_salt(...)`
-- in the RPCs below (our function search_path is locked to `public`).
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- reps — identity table. Email + 4-digit PIN auth.
-- ============================================================
create table reps (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique,
  name          text not null,
  pin_hash      text not null,
  is_admin      boolean not null default false,
  created_at    timestamptz not null default now(),
  last_drill_at timestamptz
);

-- ============================================================
-- Trigger functions — denormalize rep_name onto each row so the
-- Table Editor is readable without manual joins.
-- ============================================================

-- Populate rep_name from reps on insert
create or replace function populate_rep_name() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select name into new.rep_name from reps where id = new.rep_id;
  return new;
end;
$$;

-- Sync rep_name across denormalized tables if reps.name changes
create or replace function sync_rep_name() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.name is distinct from old.name then
    update rep_progress   set rep_name = new.name where rep_id = new.id;
    update drill_sessions set rep_name = new.name where rep_id = new.id;
    update answers        set rep_name = new.name where rep_id = new.id;
  end if;
  return new;
end;
$$;

create trigger reps_sync_name after update on reps
  for each row execute function sync_rep_name();

-- ============================================================
-- rep_progress — per-rep, per-question Leitner state.
-- Direct replacement for the localStorage `bdc_drill_state` object.
-- ============================================================
create table rep_progress (
  rep_id        uuid not null references reps(id) on delete cascade,
  rep_name      text not null,
  question_id   text not null,
  bucket        smallint not null default 1 check (bucket between 1 and 5),
  last_seen     timestamptz,
  correct_count integer not null default 0,
  wrong_count   integer not null default 0,
  primary key (rep_id, question_id)
);

create index rep_progress_rep_idx on rep_progress(rep_id);

create trigger rep_progress_populate_name before insert on rep_progress
  for each row execute function populate_rep_name();

-- ============================================================
-- drill_sessions — one row per drill attempt.
-- ============================================================
create table drill_sessions (
  id            uuid primary key default gen_random_uuid(),
  rep_id        uuid not null references reps(id) on delete cascade,
  rep_name      text not null,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  correct_count integer not null default 0,
  wrong_count   integer not null default 0
);

create index drill_sessions_rep_idx     on drill_sessions(rep_id);
create index drill_sessions_started_idx on drill_sessions(started_at desc);

create trigger drill_sessions_populate_name before insert on drill_sessions
  for each row execute function populate_rep_name();

-- ============================================================
-- answers — granular log of every question response.
-- Powers the admin dashboard.
-- ============================================================
create table answers (
  id                uuid primary key default gen_random_uuid(),
  rep_id            uuid not null references reps(id) on delete cascade,
  rep_name          text not null,
  session_id        uuid references drill_sessions(id) on delete set null,
  question_id       text not null,
  question_type     text not null,
  question_category text,
  was_correct       boolean not null,
  typed_text        text,
  selected_idx      smallint,
  grader_used       text,    -- 'keyword' | 'llm' | 'keyword-fallback' | 'exact'
  grader_feedback   text,    -- personalized feedback from LLM grader, if any
  hint_used         boolean not null default false,
  created_at        timestamptz not null default now()
);

create index answers_rep_idx      on answers(rep_id);
create index answers_question_idx on answers(question_id);
create index answers_created_idx  on answers(created_at desc);

create trigger answers_populate_name before insert on answers
  for each row execute function populate_rep_name();

-- ============================================================
-- Auth RPCs (SECURITY DEFINER — execute with table owner's privileges
-- so they can read/write `reps` even though anon can't touch it directly).
-- ============================================================

-- Register a new rep with a 4-digit PIN. Returns the new rep's UUID.
create or replace function create_rep(p_email text, p_name text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if p_pin !~ '^\d{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;

  insert into reps (email, name, pin_hash)
  values (
    lower(trim(p_email)),
    trim(p_name),
    extensions.crypt(p_pin, extensions.gen_salt('bf', 10))
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- Verify email + PIN. Returns rep_id on match, null otherwise.
create or replace function verify_pin(p_email text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  matched_id uuid;
begin
  select id into matched_id
  from reps
  where email = lower(trim(p_email))
    and pin_hash = extensions.crypt(p_pin, pin_hash);

  return matched_id;
end;
$$;

-- Fetch rep public info by id (omits pin_hash). Used after login.
create or replace function get_rep(p_id uuid)
returns table (id uuid, email text, name text, is_admin boolean, last_drill_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select id, email, name, is_admin, last_drill_at
  from reps where id = p_id;
$$;

-- ============================================================
-- Row Level Security + permissions
-- ============================================================

-- reps: RLS on, NO policies = all anon access denied at the row level.
-- The SECURITY DEFINER RPCs above run as the function owner and bypass
-- RLS, so login/registration still works.
-- Also revoke direct table grants as defense-in-depth.
alter table reps enable row level security;
revoke all on reps from anon;

grant execute on function create_rep(text, text, text) to anon;
grant execute on function verify_pin(text, text) to anon;
grant execute on function get_rep(uuid) to anon;

-- Other tables: RLS on with permissive v1 policies.
-- Trust boundary is the closed BDC team. Data is non-sensitive (drill answers).
-- v2: replace `using (true)` with policies that check a custom JWT claim
--     minted by an Edge Function after PIN verify.
alter table rep_progress   enable row level security;
alter table drill_sessions enable row level security;
alter table answers        enable row level security;

create policy "v1 open access" on rep_progress
  for all to anon using (true) with check (true);

create policy "v1 open access" on drill_sessions
  for all to anon using (true) with check (true);

create policy "v1 open access" on answers
  for all to anon using (true) with check (true);

-- ============================================================
-- Admin RPCs — analytics for the admin dashboard (admin.html).
-- Each takes p_rep_id and refuses to return data unless that rep
-- has is_admin = true. Since rep_id is a random UUID, a non-admin
-- can't guess a valid admin id. v2 should swap this for a real
-- signed-token check.
-- ============================================================

create or replace function admin_team_kpis(p_rep_id uuid)
returns table (
  total_reps        bigint,
  sessions_today    bigint,
  answers_today     bigint,
  accuracy_week     numeric,
  active_reps_week  bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select
    (select count(*) from reps),
    (select count(*) from drill_sessions where started_at >= current_date),
    (select count(*) from answers where created_at >= current_date),
    (select round(count(*) filter (where was_correct) * 100.0 / nullif(count(*), 0), 1)
       from answers where created_at >= now() - interval '7 days'),
    (select count(distinct rep_id) from drill_sessions where started_at >= now() - interval '7 days');
end;
$$;

create or replace function admin_rep_stats(p_rep_id uuid)
returns table (
  rep_id           uuid,
  name             text,
  email            text,
  session_count    bigint,
  answer_count     bigint,
  correct_count    bigint,
  wrong_count      bigint,
  accuracy         numeric,
  mastered_count   bigint,
  hints_used       bigint,
  last_drilled_at  timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select
    r.id, r.name, r.email,
    count(distinct s.id)                                                                as session_count,
    count(a.id)                                                                         as answer_count,
    count(a.id) filter (where a.was_correct)                                            as correct_count,
    count(a.id) filter (where not a.was_correct)                                        as wrong_count,
    round(count(a.id) filter (where a.was_correct) * 100.0 / nullif(count(a.id), 0), 1) as accuracy,
    (select count(*) from rep_progress p where p.rep_id = r.id and p.bucket >= 4)      as mastered_count,
    count(a.id) filter (where a.hint_used)                                              as hints_used,
    max(s.started_at)                                                                   as last_drilled_at
  from reps r
  left join drill_sessions s on s.rep_id = r.id
  left join answers a        on a.rep_id = r.id
  group by r.id, r.name, r.email
  order by last_drilled_at desc nulls last;
end;
$$;

create or replace function admin_weak_questions(p_rep_id uuid, p_min_samples int default 3)
returns table (
  question_id        text,
  question_category  text,
  total_count        bigint,
  wrong_count        bigint,
  wrong_rate         numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select
    a.question_id, a.question_category, count(*) as total_count,
    count(*) filter (where not a.was_correct)                              as wrong_count,
    round(count(*) filter (where not a.was_correct) * 100.0 / count(*), 1) as wrong_rate
  from answers a
  group by a.question_id, a.question_category
  having count(*) >= p_min_samples
  order by wrong_rate desc, total_count desc
  limit 20;
end;
$$;

create or replace function admin_recent_sessions(p_rep_id uuid, p_limit int default 25)
returns table (
  id              uuid,
  rep_name        text,
  started_at      timestamptz,
  ended_at        timestamptz,
  correct_count   integer,
  wrong_count     integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select s.id, s.rep_name, s.started_at, s.ended_at, s.correct_count, s.wrong_count
  from drill_sessions s
  order by s.started_at desc
  limit p_limit;
end;
$$;

create or replace function admin_recent_typed_answers(p_rep_id uuid, p_limit int default 30)
returns table (
  id                  uuid,
  rep_name            text,
  question_id         text,
  question_category   text,
  typed_text          text,
  was_correct         boolean,
  grader_feedback     text,
  grader_used         text,
  hint_used           boolean,
  created_at          timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select a.id, a.rep_name, a.question_id, a.question_category,
         a.typed_text, a.was_correct, a.grader_feedback, a.grader_used,
         a.hint_used, a.created_at
  from answers a
  where a.typed_text is not null
  order by a.created_at desc
  limit p_limit;
end;
$$;

grant execute on function admin_team_kpis(uuid)                       to anon;
grant execute on function admin_rep_stats(uuid)                       to anon;
grant execute on function admin_weak_questions(uuid, int)             to anon;
grant execute on function admin_recent_sessions(uuid, int)            to anon;
grant execute on function admin_recent_typed_answers(uuid, int)       to anon;
