-- Sheersho support-ticket repair
-- Run this entire file in Supabase Dashboard > SQL Editor > New query.
-- This migration is intentionally limited to ticket creation and user-side replies.

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

  insert into public.ss_support_tickets
    (user_id, subject, status, created_at, updated_at)
  values
    (v_user_id, trim(p_subject), 'open', now(), now())
  returning * into v_ticket;

  insert into public.ss_support_messages
    (ticket_id, user_id, sender_role, message, image_url, created_at)
  values
    (v_ticket.id, v_user_id, 'user', trim(p_message), p_image_url, now());

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

  insert into public.ss_support_messages
    (ticket_id, user_id, sender_role, message, image_url, created_at)
  values
    (p_ticket_id, v_user_id, 'user', nullif(trim(coalesce(p_message, '')), ''), p_image_url, now())
  returning * into v_message;

  update public.ss_support_tickets
  set updated_at = now()
  where id = p_ticket_id;

  return to_jsonb(v_message);
end;
$$;

alter table public.ss_support_tickets enable row level security;
alter table public.ss_support_messages enable row level security;

drop policy if exists "ss_support_tickets_select_own" on public.ss_support_tickets;
create policy "ss_support_tickets_select_own"
on public.ss_support_tickets
for select to authenticated
using (user_id = auth.uid());

drop policy if exists "ss_support_messages_select_own_ticket" on public.ss_support_messages;
create policy "ss_support_messages_select_own_ticket"
on public.ss_support_messages
for select to authenticated
using (
  exists (
    select 1 from public.ss_support_tickets t
    where t.id = ss_support_messages.ticket_id
      and t.user_id = auth.uid()
  )
);

grant select on public.ss_support_tickets to authenticated;
grant select on public.ss_support_messages to authenticated;
grant execute on function public.ss_support_create_ticket(text, text, text) to authenticated;
grant execute on function public.ss_support_send_message(uuid, text, text) to authenticated;
