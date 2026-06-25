-- Repair the two production blockers shown by the app:
-- 1) legacy recursive policies on public.profiles;
-- 2) legacy NULL group values caused by using only profiles.group_id.
-- Run this whole file in the Supabase SQL editor or apply it with Supabase CLI.

-- Profiles must have only non-recursive policies. Any policy that queries
-- profiles from a profiles policy can trigger: "infinite recursion detected in
-- policy for relation \"profiles\"".
do $$
declare
    pol record;
begin
    for pol in
        select policyname
        from pg_policies
        where schemaname = 'public'
          and tablename = 'profiles'
    loop
        execute format('drop policy if exists %I on public.profiles', pol.policyname);
    end loop;
end $$;

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
    for select using (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
    for update using (auth.uid() = id) with check (auth.uid() = id);

create policy "profiles_insert_own" on public.profiles
    for insert with check (auth.uid() = id);

create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select coalesce(
        lower(auth.jwt() ->> 'email') in ('victortrovo@me.com', 'contato@77estudio.com'),
        false
    );
$$;

create policy "profiles_select_admin" on public.profiles
    for select using (public.is_admin());

-- Reads the optional partnership group id. Callers must coalesce NULL to auth.uid()
-- when they need the canonical household/group key for solo users.
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

-- group_id is the household/group key. For solo users it must be the user's own
-- id; for linked users it is the partnership group id. Backfill legacy rows and
-- keep the column required so every wish can be queried by the same group logic.
update public.wishes
set group_id = owner_id
where group_id is null
  and owner_id is not null;

alter table public.wishes
    alter column group_id set not null;

create or replace function public.create_wish(wish_title text, wish_amount numeric, wish_scope text default 'personal')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    new_wish_id uuid;
    normalized_scope text;
    target_group_id uuid;
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

    target_group_id := coalesce(public.current_group_id(), auth.uid());

    insert into public.wishes (owner_id, group_id, title, amount, scope)
    values (
        auth.uid(),
        target_group_id,
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
