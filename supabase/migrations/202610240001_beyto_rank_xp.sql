-- BEYTO_RANK_SYSTEM_V1
-- Apply to the Beyto Supabase project only (tzrgixjjpkikiklkkrmh).
alter table public.ss_profiles add column if not exists xp bigint not null default 0;
create table if not exists public.ss_player_xp_events (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 points integer not null check (points between 1 and 10),
 source text not null default 'game',
 created_at timestamptz not null default now()
);
create index if not exists ss_player_xp_events_user_time_idx on public.ss_player_xp_events(user_id, created_at desc);
alter table public.ss_player_xp_events enable row level security;
revoke all on public.ss_player_xp_events from anon, authenticated;
create or replace function public.ss_award_player_xp(p_points integer, p_source text default 'game')
returns table(user_id uuid, xp bigint)
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); v_points integer; v_xp bigint; v_last timestamptz; v_daily integer;
begin
 if v_uid is null then raise exception 'Authentication required'; end if;
 v_points := least(10, greatest(1, coalesce(p_points, 0)));
 if p_points is null or p_points < 1 or p_points > 10 then raise exception 'Invalid XP award'; end if;
 select max(e.created_at) into v_last from public.ss_player_xp_events e where e.user_id = v_uid;
 if v_last is not null and v_last > now() - interval '900 milliseconds' then raise exception 'Please wait before earning XP again'; end if;
 select coalesce(sum(e.points),0)::integer into v_daily from public.ss_player_xp_events e where e.user_id = v_uid and e.created_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
 if v_daily >= 1000 then raise exception 'Daily XP limit reached'; end if;
 v_points := least(v_points, 1000-v_daily);
 insert into public.ss_player_xp_events(user_id, points, source) values(v_uid, v_points, left(coalesce(p_source,'game'),40));
 update public.ss_profiles p set xp = coalesce(p.xp,0) + v_points where p.id = v_uid returning p.xp into v_xp;
 if not found then raise exception 'Profile not found'; end if;
 return query select v_uid, v_xp;
end $$;
revoke all on function public.ss_award_player_xp(integer,text) from public, anon;
grant execute on function public.ss_award_player_xp(integer,text) to authenticated;
create or replace function public.ss_get_my_player_rank()
returns table(user_id uuid, xp bigint)
language sql stable security invoker
set search_path = public, auth
as $$ select p.id, coalesce(p.xp,0) from public.ss_profiles p where p.id = auth.uid() $$;
revoke all on function public.ss_get_my_player_rank() from public;
grant execute on function public.ss_get_my_player_rank() to authenticated;
create or replace function public.ss_get_player_ranks(p_user_ids uuid[])
returns table(user_id uuid, xp bigint)
language sql stable security definer
set search_path = public, auth
as $$ select p.id, coalesce(p.xp,0) from public.ss_profiles p where p.id = any(coalesce(p_user_ids, array[]::uuid[])) limit 100 $$;
revoke all on function public.ss_get_player_ranks(uuid[]) from public;
grant execute on function public.ss_get_player_ranks(uuid[]) to anon, authenticated;
