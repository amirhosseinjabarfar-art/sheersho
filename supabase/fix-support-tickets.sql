-- Sheersho: repair support ticket creation and user replies.
-- Run in Supabase Dashboard > SQL Editor. This creates the ticket tables if missing,
-- adds missing expected columns, and installs the RPCs used by index.html.

create extension if not exists pgcrypto;

create table if not exists public.ss_support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject text not null,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.ss_support_tickets add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.ss_support_tickets add column if not exists subject text;
alter table public.ss_support_tickets add column if not exists status text default 'open';
alter table public.ss_support_tickets add column if not exists created_at timestamptz default now();
alter table public.ss_support_tickets add column if not exists updated_at timestamptz default now();

create table if not exists public.ss_support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.ss_support_tickets(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null default 'user',
  message text,
  image_url text,
  created_at timestamptz not null default now()
);

alter table public.ss_support_messages add column if not exists ticket_id uuid references public.ss_support_tickets(id) on delete cascade;
alter table public.ss_support_messages add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.ss_support_messages add column if not exists sender_role text default 'user';
alter table public.ss_support_messages add column if not exists message text;
alter table public.ss_support_messages add column if not exists image_url text;
alter table public.ss_support_messages add column if not exists created_at timestamptz default now();

create index if not exists ss_support_tickets_user_updated_idx
  on public.ss_support_tickets(user_id, updated_at desc);
create index if not exists ss_support_messages_ticket_created_idx
  on public.ss_support_messages(ticket_id, created_at asc);

create or replace function public.ss_support_create_ticket(
  p_subject text,
  p_message text,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_ticket public.ss_support_tickets%rowtype;
begin
  if v_user_id is null then
    raise exception 'ابتدا وارد حساب شو.';
  end if;
  if length(trim(coalesce(p_subject, ''))) < 3 then
    raise exception 'موضوع تیکت باید حداقل ۳ حرف باشد.';
  end if;
  if length(trim(coalesce(p_message, ''))) < 2 then
    raise exception 'متن پیام باید حداقل ۲ حرف باشد.';
  end if;

  insert into public.ss_support_tickets(user_id, subject, status, created_at, updated_at)
  values (v_user_id, trim(p_subject), 'open', now(), now())
  returning * into v_ticket;

  insert into public.ss_support_messages(ticket_id, user_id, sender_role, message, image_url, created_at)
  values (v_ticket.id, v_user_id, 'user', trim(p_message), p_image_url, now());

  return jsonb_build_object('ticket', to_jsonb(v_ticket));
end;
$$;

create or replace function public.ss_support_send_message(
  p_ticket_id uuid,
  p_message text,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_ticket public.ss_support_tickets%rowtype;
  v_message public.ss_support_messages%rowtype;
begin
  if v_user_id is null then
    raise exception 'ابتدا وارد حساب شو.';
  end if;
  select * into v_ticket
  from public.ss_support_tickets
  where id = p_ticket_id and user_id = v_user_id
  for update;
  if not found then
    raise exception 'تیکت پیدا نشد یا دسترسی نداری.';
  end if;
  if v_ticket.status = 'closed' then
    raise exception 'این تیکت بسته شده است.';
  end if;
  if length(trim(coalesce(p_message, ''))) = 0 and nullif(trim(coalesce(p_image_url, '')), '') is null then
    raise exception 'متن یا تصویر پیام را وارد کن.';
  end if;

  insert into public.ss_support_messages(ticket_id, user_id, sender_role, message, image_url, created_at)
  values (p_ticket_id, v_user_id, 'user', nullif(trim(coalesce(p_message, '')), ''), p_image_url, now())
  returning * into v_message;

  update public.ss_support_tickets set updated_at = now() where id = p_ticket_id;
  return to_jsonb(v_message);
end;
$$;

alter table public.ss_support_tickets enable row level security;
alter table public.ss_support_messages enable row level security;

drop policy if exists "ss_support_tickets_select_own" on public.ss_support_tickets;
create policy "ss_support_tickets_select_own" on public.ss_support_tickets
for select to authenticated using (user_id = auth.uid());

drop policy if exists "ss_support_messages_select_own_ticket" on public.ss_support_messages;
create policy "ss_support_messages_select_own_ticket" on public.ss_support_messages
for select to authenticated using (
  exists (select 1 from public.ss_support_tickets t
          where t.id = ss_support_messages.ticket_id and t.user_id = auth.uid())
);

grant select on public.ss_support_tickets to authenticated;
grant select on public.ss_support_messages to authenticated;
grant execute on function public.ss_support_create_ticket(text, text, text) to authenticated;
grant execute on function public.ss_support_send_message(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
