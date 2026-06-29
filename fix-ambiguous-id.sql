-- BDC Flash Drill — Fix "column reference id is ambiguous"
-- Run in: Supabase Dashboard → SQL Editor → New Query → paste → Run
--
-- Three admin RPCs declare an OUT column named `id`, which collides with the
-- unqualified `id` in the auth check `where id = p_rep_id`. Qualify it as
-- `reps.id`. Return signatures are unchanged, so create-or-replace is enough
-- (no drop needed).

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
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
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
  if not exists (select 1 from reps where reps.id = p_rep_id and is_admin) then
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
