-- Keep wishes.group_id as the canonical household/group key.
-- Solo users use their own auth.uid(); partnered users use profiles.group_id.
-- This file also repairs databases where the previous hotfix was already run.

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
