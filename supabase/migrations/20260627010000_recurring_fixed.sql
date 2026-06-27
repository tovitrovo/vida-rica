-- ============================================================================
-- Gastos fixos recorrentes (repetem mês a mês)
-- ----------------------------------------------------------------------------
-- Um "template" de gasto fixo gera um lançamento virtual em cada mês a partir
-- de start_ym (inclusive) até end_ym (inclusive, ou aberto se null).
-- Exclusões pontuais ("só neste mês") ficam em skip_yms.
-- O acesso segue o mesmo padrão de grupo (casal/trisal) de transactions.
-- ============================================================================

create table if not exists public.recurring_fixed (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null default auth.uid(),
    group_id    uuid not null,
    description text not null,
    amount      numeric(12,2) not null check (amount >= 0),
    start_ym    text not null,                 -- 'YYYY-MM' primeiro mês que vale
    end_ym      text,                          -- 'YYYY-MM' último mês (null = aberto)
    skip_yms    text[] not null default '{}',  -- meses pulados ("excluir só neste mês")
    active      boolean not null default true,
    created_at  timestamptz not null default now()
);

create index if not exists idx_recurring_fixed_group on public.recurring_fixed (group_id);
create index if not exists idx_recurring_fixed_user  on public.recurring_fixed (user_id);

alter table public.recurring_fixed enable row level security;

drop policy if exists "recurring_fixed_select_group" on public.recurring_fixed;
create policy "recurring_fixed_select_group" on public.recurring_fixed
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

drop policy if exists "recurring_fixed_insert_own" on public.recurring_fixed;
create policy "recurring_fixed_insert_own" on public.recurring_fixed
    for insert with check (auth.uid() = user_id);

-- Atualização e exclusão liberadas para o grupo: ambos os parceiros podem
-- pular ou encerrar um gasto fixo compartilhado da casa.
drop policy if exists "recurring_fixed_update_group" on public.recurring_fixed;
create policy "recurring_fixed_update_group" on public.recurring_fixed
    for update using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    ) with check (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "recurring_fixed_delete_group" on public.recurring_fixed;
create policy "recurring_fixed_delete_group" on public.recurring_fixed
    for delete using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

grant select, insert, update, delete on table public.recurring_fixed to authenticated;
