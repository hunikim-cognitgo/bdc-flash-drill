-- BDC Flash Drill — Admin RPCs
-- Run in: Supabase Dashboard → SQL Editor → New Query → paste → Run
--
-- Each function takes p_rep_id and refuses to return data unless that rep
-- has is_admin = true. Since the rep_id is a random UUID, a non-admin can't
-- guess a valid admin id. v2 should swap this for a real signed-token check.

-- ============================================================
-- 1. Team-wide KPIs (one row)
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
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
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

-- ============================================================
-- 2. Per-rep leaderboard
-- ============================================================
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
  last_drilled_at  timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select
    r.id,
    r.name,
    r.email,
    count(distinct s.id)                                                            as session_count,
    count(a.id)                                                                     as answer_count,
    count(a.id) filter (where a.was_correct)                                        as correct_count,
    count(a.id) filter (where not a.was_correct)                                    as wrong_count,
    round(count(a.id) filter (where a.was_correct) * 100.0 / nullif(count(a.id), 0), 1) as accuracy,
    (select count(*) from rep_progress p where p.rep_id = r.id and p.bucket >= 4)  as mastered_count,
    max(s.started_at)                                                               as last_drilled_at
  from reps r
  left join drill_sessions s on s.rep_id = r.id
  left join answers a        on a.rep_id = r.id
  group by r.id, r.name, r.email
  order by last_drilled_at desc nulls last;
end;
$$;

-- ============================================================
-- 3. Weakest questions team-wide
-- ============================================================
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
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select
    a.question_id,
    a.question_category,
    count(*)                                                            as total_count,
    count(*) filter (where not a.was_correct)                           as wrong_count,
    round(count(*) filter (where not a.was_correct) * 100.0 / count(*), 1) as wrong_rate
  from answers a
  group by a.question_id, a.question_category
  having count(*) >= p_min_samples
  order by wrong_rate desc, total_count desc
  limit 20;
end;
$$;

-- ============================================================
-- 4. Recent sessions
-- ============================================================
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
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select s.id, s.rep_name, s.started_at, s.ended_at, s.correct_count, s.wrong_count
  from drill_sessions s
  order by s.started_at desc
  limit p_limit;
end;
$$;

-- ============================================================
-- 5. Recent typed answers (with LLM feedback)
-- ============================================================
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
  created_at          timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
    raise exception 'not authorized';
  end if;
  return query
  select a.id, a.rep_name, a.question_id, a.question_category,
         a.typed_text, a.was_correct, a.grader_feedback, a.grader_used, a.created_at
  from answers a
  where a.typed_text is not null
  order by a.created_at desc
  limit p_limit;
end;
$$;

-- ============================================================
-- Permissions
-- ============================================================
grant execute on function admin_team_kpis(uuid)                       to anon;
grant execute on function admin_rep_stats(uuid)                       to anon;
grant execute on function admin_weak_questions(uuid, int)             to anon;
grant execute on function admin_recent_sessions(uuid, int)            to anon;
grant execute on function admin_recent_typed_answers(uuid, int)       to anon;
