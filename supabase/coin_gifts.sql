-- شعرشو: انتقال امن سکه و تاریخچه هدیه‌ها
-- این اسکریپت در Supabase SQL Editor اجرا شود.
-- ساختار مطابق کد فعلی سایت: ss_profiles(id, username, coins)، ss_friends(user_id, friend_id)

begin;

create table if not exists public.ss_coin_gifts (
  id bigint generated always as identity primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  sender_username text not null default '',
  recipient_username text not null default '',
  amount integer not null check (amount > 0),
  created_at timestamptz not null default now()
);

alter table public.ss_coin_gifts enable row level security;

drop policy if exists "Recipients can read their coin gifts"
  on public.ss_coin_gifts;

create policy "Recipients can read their coin gifts"
  on public.ss_coin_gifts
  for select to authenticated
  using (recipient_id = auth.uid());

revoke all on table public.ss_coin_gifts from anon, authenticated;
grant select on table public.ss_coin_gifts to authenticated;

create or replace function public.ss_gift_coins(
  p_recipient_id uuid,
  p_amount integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_sender uuid := auth.uid();
  v_sender_coins integer;
  v_sender_username text;
  v_recipient_username text;
begin
  if v_sender is null then
    raise exception 'ابتدا وارد حساب شو.';
  end if;

  if p_recipient_id is null or p_recipient_id = v_sender then
    raise exception 'گیرنده معتبر نیست.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'تعداد سکه باید عدد صحیح مثبت باشد.';
  end if;

  -- قفل حساب‌ها به ترتیب ثابت برای جلوگیری از انتقال هم‌زمان ناسازگار
  perform p.id
  from public.ss_profiles as p
  where p.id in (v_sender, p_recipient_id)
  order by p.id
  for update;

  select p.coins, coalesce(p.username, '')
    into v_sender_coins, v_sender_username
  from public.ss_profiles as p
  where p.id = v_sender;

  if not found then
    raise exception 'پروفایل فرستنده پیدا نشد.';
  end if;

  select coalesce(p.username, '')
    into v_recipient_username
  from public.ss_profiles as p
  where p.id = p_recipient_id;

  if not found then
    raise exception 'پروفایل گیرنده پیدا نشد.';
  end if;

  if not exists (
    select 1
    from public.ss_friends as f
    where f.user_id = v_sender
      and f.friend_id = p_recipient_id
  ) then
    raise exception 'فقط به دوست تأییدشده می‌توانی سکه هدیه بدهی.';
  end if;

  if coalesce(v_sender_coins, 0) < p_amount then
    raise exception 'موجودی سکه کافی نیست.';
  end if;

  update public.ss_profiles
    set coins = coalesce(coins, 0) - p_amount
  where id = v_sender;

  update public.ss_profiles
    set coins = coalesce(coins, 0) + p_amount
  where id = p_recipient_id;

  insert into public.ss_coin_gifts (
    sender_id, recipient_id, sender_username, recipient_username, amount
  ) values (
    v_sender, p_recipient_id, v_sender_username, v_recipient_username, p_amount
  );

  return jsonb_build_object(
    'success', true,
    'remaining_coins', v_sender_coins - p_amount,
    'amount', p_amount
  );
end;
$function$;

create or replace function public.ss_my_coin_gifts()
returns table (
  sender_username text,
  sender_display_name text,
  amount integer,
  created_at timestamptz
)
language sql
security definer
set search_path = ''
as $function$
  select
    g.sender_username,
    g.sender_username as sender_display_name,
    g.amount,
    g.created_at
  from public.ss_coin_gifts as g
  where g.recipient_id = auth.uid()
  order by g.created_at desc
  limit 100;
$function$;

revoke all on function public.ss_gift_coins(uuid, integer) from public, anon;
grant execute on function public.ss_gift_coins(uuid, integer) to authenticated;

revoke all on function public.ss_my_coin_gifts() from public, anon;
grant execute on function public.ss_my_coin_gifts() to authenticated;

commit;
