-- Fix RLS recursion when creating or reading wishes.
-- Run this whole file in the Supabase SQL editor; do not remove the leading "--" from comment lines.

create or replace function public.current_group_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
    select p.group_id
    from public.profiles p
    where p.id = auth.uid();
$$;

revoke execute on function public.current_group_id() from public, anon;
grant execute on function public.current_group_id() to authenticated;

drop policy if exists "transactions_select_group" on public.transactions;
create policy "transactions_select_group" on public.transactions
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "subscriptions_select_group" on public.subscriptions;
create policy "subscriptions_select_group" on public.subscriptions
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

drop policy if exists "mentorship_bookings_select_group" on public.mentorship_bookings;
create policy "mentorship_bookings_select_group" on public.mentorship_bookings
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

drop policy if exists "wishes_select_group" on public.wishes;
create policy "wishes_select_group" on public.wishes
    for select using (
        auth.uid() = owner_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "wishes_insert_own" on public.wishes;
create policy "wishes_insert_own" on public.wishes
    for insert with check (auth.uid() = owner_id);

drop policy if exists "wishes_update_group" on public.wishes;
create policy "wishes_update_group" on public.wishes
    for update using (
        auth.uid() = owner_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    )
    with check (
        auth.uid() = owner_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "wishes_delete_own" on public.wishes;
create policy "wishes_delete_own" on public.wishes
    for delete using (auth.uid() = owner_id);

drop policy if exists "wish_contributions_select_group" on public.wish_contributions;
create policy "wish_contributions_select_group" on public.wish_contributions
    for select using (
        wish_id in (
            select w.id from public.wishes w
            where w.owner_id = auth.uid()
               or w.group_id = auth.uid()
               or w.group_id = public.current_group_id()
        )
    );

drop policy if exists "wish_contributions_insert_own" on public.wish_contributions;
create policy "wish_contributions_insert_own" on public.wish_contributions
    for insert with check (
        auth.uid() = user_id
        and wish_id in (
            select w.id from public.wishes w
            where w.owner_id = auth.uid()
               or w.group_id = auth.uid()
               or w.group_id = public.current_group_id()
        )
    );

create or replace function public.create_wish(wish_title text, wish_amount numeric, wish_scope text default 'personal')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    new_wish_id uuid;
    normalized_scope text;
begin
    if auth.uid() is null then
        raise exception 'not_authenticated';
    end if;

    if nullif(btrim(wish_title), '') is null then
        raise exception 'invalid_wish_title';
    end if;

    if wish_amount is null or wish_amount <= 0 then
        raise exception 'invalid_wish_amount';
    end if;

    normalized_scope := coalesce(nullif(btrim(wish_scope), ''), 'personal');
    if normalized_scope not in ('personal', 'shared') then
        raise exception 'invalid_wish_scope';
    end if;

    insert into public.wishes (owner_id, group_id, title, amount, scope)
    values (
        auth.uid(),
        public.current_group_id(),
        btrim(wish_title),
        wish_amount,
        normalized_scope
    )
    returning id into new_wish_id;

    return new_wish_id;
end;
$$;

revoke execute on function public.create_wish(text, numeric, text) from public, anon;
grant execute on function public.create_wish(text, numeric, text) to authenticated;
