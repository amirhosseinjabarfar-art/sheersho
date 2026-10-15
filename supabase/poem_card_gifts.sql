-- شعرشو: کارت شعر سکه‌ای و هدیه کارت به دوستان
-- این فایل را یک‌بار در Supabase > SQL Editor اجرا کن.

begin;

create table if not exists public.ss_poem_card_gifts (
  id bigint generated always as identity primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  poem_key text not null check (poem_key in ('tavana','khoda')),
  poem_title text not null,
  poem_verse text not null,
  poem_author text not null default 'فردوسی',
  sender_username text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.ss_poem_cards (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  poem_key text not null check (poem_key in ('tavana','khoda')),
  poem_title text not null,
  poem_verse text not null,
  poem_author text not null default 'فردوسی',
  received_from uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.ss_poem_card_gifts enable row level security;
alter table public.ss_poem_cards enable row level security;

drop policy if exists "Recipients read pending poem card gifts" on public.ss_poem_card_gifts;
create policy "Recipients read pending poem card gifts" on public.ss_poem_card_gifts
  for select to authenticated using (recipient_id = auth.uid());

drop policy if exists "Owners read poem cards" on public.ss_poem_cards;
create policy "Owners read poem cards" on public.ss_poem_cards
  for select to authenticated using (owner_id = auth.uid());

revoke all on table public.ss_poem_card_gifts from anon, authenticated;
revoke all on table public.ss_poem_cards from anon, authenticated;
grant select on table public.ss_poem_card_gifts to authenticated;
grant select on table public.ss_poem_cards to authenticated;

drop function if exists public.ss_send_poem_card_gift(text, uuid);
drop function if exists public.ss_send_poem_card_gift(uuid, text);

create or replace function public.ss_send_poem_card_gift(p_recipient_id uuid, p_poem_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_sender_name text := '';
  v_recipient_name text := '';
  v_title text;
  v_verse text;
  v_author text := 'فردوسی';
  v_balance integer;
begin
  if v_sender is null then return jsonb_build_object('success',false,'message','ابتدا وارد حساب شو.'); end if;
  if p_recipient_id is null or p_recipient_id = v_sender then return jsonb_build_object('success',false,'message','گیرنده معتبر نیست.'); end if;

  if p_poem_key = 'tavana' then
    v_title := 'توانا بود هر که دانا بود';
    v_verse := E'توانا بود هر که دانا بود\nز دانش دل پیر برنا بود';
  elsif p_poem_key = 'khoda' then
    v_title := 'به نام خداوند جان و خرد';
    v_verse := E'به نام خداوند جان و خرد\nکزین برتر اندیشه برنگذرد';
  else
    return jsonb_build_object('success',false,'message','کارت شعر انتخابی معتبر نیست.');
  end if;

  if not exists (
    select 1 from public.ss_friends f
    where f.user_id = v_sender and f.friend_id = p_recipient_id
  ) then
    return jsonb_build_object('success',false,'message','فقط می‌توانی به دوست تأییدشده کارت بفرستی.');
  end if;

  select coalesce(username,'') into v_sender_name from public.ss_profiles where id = v_sender;
  select coalesce(username,'') into v_recipient_name from public.ss_profiles where id = p_recipient_id;

  select coins into v_balance from public.ss_profiles where id = v_sender for update;
  if v_balance is null then return jsonb_build_object('success',false,'message','پروفایل فرستنده پیدا نشد.'); end if;
  if v_balance < 50 then return jsonb_build_object('success',false,'message','برای ارسال کارت به ۵۰ سکه نیاز داری.'); end if;

  update public.ss_profiles set coins = coins - 50 where id = v_sender;

  insert into public.ss_poem_card_gifts
    (sender_id,recipient_id,poem_key,poem_title,poem_verse,poem_author,sender_username)
  values
    (v_sender,p_recipient_id,p_poem_key,v_title,v_verse,v_author,v_sender_name);

  return jsonb_build_object('success',true,'cost',50,'recipient_username',v_recipient_name);
end;
$$;

create or replace function public.ss_my_pending_poem_card_gifts()
returns table(id bigint, poem_key text, poem_title text, poem_verse text, poem_author text, sender_username text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select g.id,g.poem_key,g.poem_title,g.poem_verse,g.poem_author,g.sender_username,g.created_at
  from public.ss_poem_card_gifts g
  where g.recipient_id = auth.uid()
  order by g.created_at desc;
$$;

create or replace function public.ss_my_poem_cards()
returns table(id bigint, poem_key text, poem_title text, poem_verse text, poem_author text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select c.id,c.poem_key,c.poem_title,c.poem_verse,c.poem_author,c.created_at
  from public.ss_poem_cards c
  where c.owner_id = auth.uid()
  order by c.created_at desc;
$$;

create or replace function public.ss_claim_poem_card_gift(p_gift_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gift public.ss_poem_card_gifts%rowtype;
begin
  if auth.uid() is null then return jsonb_build_object('success',false,'message','ابتدا وارد حساب شو.'); end if;
  delete from public.ss_poem_card_gifts
   where id = p_gift_id and recipient_id = auth.uid()
   returning * into v_gift;
  if not found then return jsonb_build_object('success',false,'message','این هدیه قبلاً دریافت شده یا برای حساب تو نیست.'); end if;

  insert into public.ss_poem_cards(owner_id,poem_key,poem_title,poem_verse,poem_author,received_from)
  values(v_gift.recipient_id,v_gift.poem_key,v_gift.poem_title,v_gift.poem_verse,v_gift.poem_author,v_gift.sender_id);

  return jsonb_build_object('success',true,'message','کارت شعر دریافت شد.');
end;
$$;

revoke all on function public.ss_send_poem_card_gift(uuid,text) from public, anon;
revoke all on function public.ss_my_pending_poem_card_gifts() from public, anon;
revoke all on function public.ss_my_poem_cards() from public, anon;
revoke all on function public.ss_claim_poem_card_gift(bigint) from public, anon;
grant execute on function public.ss_send_poem_card_gift(uuid,text) to authenticated;
grant execute on function public.ss_my_pending_poem_card_gifts() to authenticated;
grant execute on function public.ss_my_poem_cards() to authenticated;
grant execute on function public.ss_claim_poem_card_gift(bigint) to authenticated;

-- Refresh PostgREST so the RPC becomes visible immediately.
notify pgrst, 'reload schema';

commit;
