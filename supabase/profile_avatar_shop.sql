-- شعرشو: فروشگاه آواتار پروفایل با قیمت ثابت ۵۰۰ سکه
-- ۱) این فایل را در Supabase SQL Editor اجرا کنید.
-- ۲) تصاویر را در Supabase Storage آپلود و URL عمومی هر تصویر را در ss_profile_avatars ثبت کنید.
-- ۳) هر آواتار در هر حساب فقط یک بار قابل خرید است؛ خرید و کسر سکه اتمیک است.

begin;

create table if not exists public.ss_profile_avatars (
  id text primary key,
  name text not null,
  image_url text not null,
  price integer not null default 500 check (price = 500),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint ss_profile_avatars_image_url_nonempty check (length(trim(image_url)) > 0)
);

create table if not exists public.ss_user_profile_avatars (
  user_id uuid not null references auth.users(id) on delete cascade,
  avatar_id text not null references public.ss_profile_avatars(id) on delete restrict,
  purchased_at timestamptz not null default now(),
  primary key (user_id, avatar_id)
);

alter table public.ss_profiles
  add column if not exists active_avatar_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'ss_profiles_active_avatar_id_fkey'
      and conrelid = 'public.ss_profiles'::regclass
  ) then
    alter table public.ss_profiles
      add constraint ss_profiles_active_avatar_id_fkey
      foreign key (active_avatar_id)
      references public.ss_profile_avatars(id)
      on delete set null;
  end if;
end $$;

alter table public.ss_profile_avatars enable row level security;
alter table public.ss_user_profile_avatars enable row level security;

drop policy if exists "Read active profile avatars" on public.ss_profile_avatars;
create policy "Read active profile avatars"
  on public.ss_profile_avatars for select to authenticated
  using (is_active = true);

drop policy if exists "Read own profile avatar purchases" on public.ss_user_profile_avatars;
create policy "Read own profile avatar purchases"
  on public.ss_user_profile_avatars for select to authenticated
  using (user_id = auth.uid());

revoke all on table public.ss_profile_avatars from anon, authenticated;
grant select on table public.ss_profile_avatars to authenticated;
revoke all on table public.ss_user_profile_avatars from anon, authenticated;
grant select on table public.ss_user_profile_avatars to authenticated;

create or replace function public.ss_my_profile_avatars()
returns table (
  id text,
  name text,
  image_url text,
  price integer,
  owned boolean,
  active boolean
)
language sql
security definer
set search_path = ''
as $function$
  select
    a.id,
    a.name,
    a.image_url,
    a.price,
    (u.avatar_id is not null) as owned,
    (p.active_avatar_id = a.id) as active
  from public.ss_profile_avatars as a
  left join public.ss_user_profile_avatars as u
    on u.avatar_id = a.id and u.user_id = auth.uid()
  left join public.ss_profiles as p
    on p.id = auth.uid()
  where a.is_active = true
  order by a.created_at, a.id;
$function$;

create or replace function public.ss_buy_profile_avatar(p_avatar_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_price integer;
  v_balance integer;
begin
  if v_user_id is null then
    raise exception 'ابتدا وارد حساب شو.';
  end if;

  if p_avatar_id is null or length(trim(p_avatar_id)) = 0 then
    raise exception 'آواتار معتبر نیست.';
  end if;

  select a.price into v_price
  from public.ss_profile_avatars as a
  where a.id = p_avatar_id and a.is_active = true;

  if not found then
    raise exception 'این آواتار در دسترس نیست.';
  end if;

  -- قفل ردیف پروفایل، خریدهای هم‌زمان را سریالی می‌کند.
  select coalesce(p.coins, 0) into v_balance
  from public.ss_profiles as p
  where p.id = v_user_id
  for update;

  if not found then
    raise exception 'پروفایل حساب پیدا نشد.';
  end if;

  if exists (
    select 1 from public.ss_user_profile_avatars as u
    where u.user_id = v_user_id and u.avatar_id = p_avatar_id
  ) then
    raise exception 'این آواتار را قبلاً خریده‌ای.';
  end if;

  if v_balance < v_price then
    raise exception 'موجودی سکه کافی نیست.';
  end if;

  update public.ss_profiles
  set coins = coalesce(coins, 0) - v_price,
      active_avatar_id = p_avatar_id
  where id = v_user_id
  returning coins into v_balance;

  insert into public.ss_user_profile_avatars (user_id, avatar_id)
  values (v_user_id, p_avatar_id);

  return jsonb_build_object(
    'success', true,
    'avatar_id', p_avatar_id,
    'remaining_coins', v_balance,
    'active_avatar_id', p_avatar_id
  );
end;
$function$;

create or replace function public.ss_set_profile_avatar(p_avatar_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'ابتدا وارد حساب شو.';
  end if;

  perform 1 from public.ss_profiles
  where id = v_user_id
  for update;

  if not found then
    raise exception 'پروفایل حساب پیدا نشد.';
  end if;

  if not exists (
    select 1 from public.ss_user_profile_avatars
    where user_id = v_user_id and avatar_id = p_avatar_id
  ) then
    raise exception 'این آواتار در دارایی‌های حساب تو نیست.';
  end if;

  update public.ss_profiles
  set active_avatar_id = p_avatar_id
  where id = v_user_id;

  return jsonb_build_object('success', true, 'active_avatar_id', p_avatar_id);
end;
$function$;

revoke all on function public.ss_my_profile_avatars() from public, anon;
grant execute on function public.ss_my_profile_avatars() to authenticated;
revoke all on function public.ss_buy_profile_avatar(text) from public, anon;
grant execute on function public.ss_buy_profile_avatar(text) to authenticated;
revoke all on function public.ss_set_profile_avatar(text) from public, anon;
grant execute on function public.ss_set_profile_avatar(text) to authenticated;

commit;

-- نمونه ثبت تصویر (پس از آپلود فایل و جایگزین‌کردن URL):
-- insert into public.ss_profile_avatars (id, name, image_url)
-- values ('avatar-01', 'آواتار شماره ۱', 'https://YOUR-PROJECT.supabase.co/storage/v1/object/public/profile-avatars/avatar-01.png');
