-- Normalize legacy wishes schemas that still require target_amount.
--
-- The application and create_wish() function use public.wishes.amount. Some
-- existing databases may still have a legacy target_amount column marked as
-- NOT NULL, which rejects inserts that only provide amount.

-- Ensure the current column expected by the app exists.
alter table public.wishes
    add column if not exists amount numeric(14, 2) not null default 0;

-- If a legacy target_amount column exists, copy any useful values into amount
-- and then relax it so inserts through create_wish() are not rejected.
do $$
begin
    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'wishes'
          and column_name = 'target_amount'
    ) then
        update public.wishes
           set amount = target_amount
         where target_amount is not null
           and (amount is null or amount = 0);

        alter table public.wishes
            alter column target_amount drop not null;

        alter table public.wishes
            alter column target_amount set default 0;
    end if;
end $$;
