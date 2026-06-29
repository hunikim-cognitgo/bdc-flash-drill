-- BDC Flash Drill — Per-rep drill-down RPCs
-- Run in: Supabase Dashboard → SQL Editor → New Query → paste → Run
--
-- Powers the admin dashboard's per-rep detail view. Each takes the admin's
-- id (p_rep_id, for the auth gate) and the target rep's id (p_target).

-- ============================================================
-- 1. Category breakdown for one rep (weakest first)
-- ============================================================
create or replace function admin_rep_category_breakdown(p_rep_id uuid, p_target uuid)
returns table (
  question_category  text,
  total              bigint,
  correct            bigint,
  wrong              bigint,
  accuracy           numeric
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
    a.question_category,
    count(*)                                                          as total,
    count(*) filter (where a.was_correct)                            as correct,
    count(*) filter (where not a.was_correct)                        as wrong,
    round(count(*) filter (where a.was_correct) * 100.0 / count(*), 1) as accuracy
  from answers a
  where a.rep_id = p_target
  group by a.question_category
  order by accuracy asc nulls last, total desc;
end;
$$;

-- ============================================================
-- 2. Per-question Leitner state for one rep (least mastered first).
--    Category pulled from the rep's own most recent answer per question.
-- ============================================================
create or replace function admin_rep_progress(p_rep_id uuid, p_target uuid)
returns table (
  question_id        text,
  question_category  text,
  bucket             smallint,
  correct_count      integer,
  wrong_count        integer,
  last_seen          timestamptz
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
    rp.question_id,
    (select a.question_category from answers a
       where a.question_id = rp.question_id and a.rep_id = rp.rep_id
       order by a.created_at desc limit 1) as question_category,
    rp.bucket, rp.correct_count, rp.wrong_count, rp.last_seen
  from rep_progress rp
  where rp.rep_id = p_target
  order by rp.bucket asc, rp.wrong_count desc;
end;
$$;

-- ============================================================
-- 3. Recent typed answers for one rep (with LLM feedback)
-- ============================================================
create or replace function admin_rep_typed_answers(p_rep_id uuid, p_target uuid, p_limit int default 40)
returns table (
  id                  uuid,
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
  select a.id, a.question_id, a.question_category, a.typed_text,
         a.was_correct, a.grader_feedback, a.grader_used, a.hint_used, a.created_at
  from answers a
  where a.rep_id = p_target and a.typed_text is not null
  order by a.created_at desc
  limit p_limit;
end;
$$;

-- ============================================================
-- Permissions
-- ============================================================
grant execute on function admin_rep_category_breakdown(uuid, uuid)   to anon;
grant execute on function admin_rep_progress(uuid, uuid)             to anon;
grant execute on function admin_rep_typed_answers(uuid, uuid, int)   to anon;
