-- BDC Flash Drill — Hint tracking patch
-- Run in: Supabase Dashboard → SQL Editor → New Query → paste → Run
--
-- Adds hint_used column to answers and updates two admin RPCs to surface
-- hint usage. Idempotent.

-- ============================================================
-- 1. Add hint_used column
-- ============================================================
alter table answers add column if not exists hint_used boolean not null default false;

-- ============================================================
-- 2. Drop the two RPCs whose return signature is changing.
--    create-or-replace can't change the return type — must drop first.
-- ============================================================
drop function if exists admin_rep_stats(uuid);
drop function if exists admin_recent_typed_answers(uuid, int);

-- ============================================================
-- 3. Per-rep leaderboard — now includes hints_used
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

-- ============================================================
-- 4. Recent typed answers — now includes hint_used
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

-- ============================================================
-- 5. Re-grant execute (drops removed the grants)
-- ============================================================
grant execute on function admin_rep_stats(uuid)                       to anon;
grant execute on function admin_recent_typed_answers(uuid, int)       to anon;
