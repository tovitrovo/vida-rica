-- Avoid foreign-key failures when a user creates a wish before their profile
-- row exists or before they are linked to a partnership group.
--
-- Some existing databases have a wishes.group_id foreign key (for example to
-- profiles.id). Personal wishes do not need a group row because owner_id already
-- scopes access, so create_wish() must not fall back to auth.uid() for group_id.

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
