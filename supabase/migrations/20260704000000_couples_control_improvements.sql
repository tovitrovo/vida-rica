-- ============================================================================
-- Melhorias de controle financeiro para casais/trisais
-- ----------------------------------------------------------------------------
-- 1. transactions.shared     — entra no rateio do saldo entre parceiros
-- 2. transactions.is_private — some do extrato/rateio de quem não é o dono
-- 3. transactions.category   — categoria livre (só usada em "gastos livres")
-- 4. recurring_fixed.due_day — dia do mês em que o gasto fixo vence (alerta)
-- 5. tabela budgets          — limite mensal por categoria, por grupo
-- 6. tabela settlements      — ajustes de "quitação" do saldo entre parceiros
-- ============================================================================

alter table public.transactions add column if not exists shared     boolean not null default true;
alter table public.transactions add column if not exists is_private boolean not null default false;
alter table public.transactions add column if not exists category   text;

alter table if exists public.recurring_fixed add column if not exists due_day int;
do $$
begin
    if exists (select 1 from information_schema.tables
               where table_schema = 'public' and table_name = 'recurring_fixed')
       and not exists (select 1 from pg_constraint where conname = 'recurring_fixed_due_day_chk')
    then
        alter table public.recurring_fixed
            add constraint recurring_fixed_due_day_chk check (due_day is null or (due_day between 1 and 31));
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- Um lançamento privado não faz sentido entrar no rateio do casal/trisal
-- (ninguém mais enxerga esse gasto para saber que "pagou a parte"). Zeramos
-- o flag de compartilhado sempre que marcarem como privado.
-- ----------------------------------------------------------------------------
update public.transactions set shared = false where is_private = true;

create or replace function public.enforce_private_not_shared()
returns trigger
language plpgsql
as $$
begin
    if new.is_private then
        new.shared := false;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_enforce_private_not_shared on public.transactions;
create trigger trg_enforce_private_not_shared
    before insert or update on public.transactions
    for each row execute function public.enforce_private_not_shared();

-- ----------------------------------------------------------------------------
-- RLS de transactions: lançamento privado só é visível para o próprio dono,
-- mesmo que o group_id bata com o do grupo.
-- ----------------------------------------------------------------------------
drop policy if exists "transactions_select_group" on public.transactions;
create policy "transactions_select_group" on public.transactions
    for select using (
        auth.uid() = user_id
        or (
            not is_private
            and (group_id = auth.uid() or group_id = public.current_group_id())
        )
        or public.is_admin()
    );

-- ============================================================================
-- TABELA: public.budgets
--         Limite mensal por categoria de "gasto livre", por grupo.
-- ============================================================================
create table if not exists public.budgets (
    id            uuid primary key default gen_random_uuid(),
    group_id      uuid not null,
    category      text not null,
    monthly_limit numeric(14, 2) not null default 0,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (group_id, category)
);

create index if not exists idx_budgets_group on public.budgets (group_id);

alter table public.budgets enable row level security;

drop policy if exists "budgets_select_group" on public.budgets;
create policy "budgets_select_group" on public.budgets
    for select using (
        group_id = auth.uid() or group_id = public.current_group_id() or public.is_admin()
    );

drop policy if exists "budgets_insert_group" on public.budgets;
create policy "budgets_insert_group" on public.budgets
    for insert with check (
        group_id = auth.uid() or group_id = public.current_group_id()
    );

drop policy if exists "budgets_update_group" on public.budgets;
create policy "budgets_update_group" on public.budgets
    for update using (
        group_id = auth.uid() or group_id = public.current_group_id()
    ) with check (
        group_id = auth.uid() or group_id = public.current_group_id()
    );

drop policy if exists "budgets_delete_group" on public.budgets;
create policy "budgets_delete_group" on public.budgets
    for delete using (
        group_id = auth.uid() or group_id = public.current_group_id()
    );

grant select, insert, update, delete on table public.budgets to authenticated;

-- ============================================================================
-- TABELA: public.settlements
--         Ajuste de "quitação" do saldo entre parceiros num mês (competência).
--         Ao quitar, gravamos um ajuste por pessoa que zera o saldo do mês.
-- ============================================================================
create table if not exists public.settlements (
    id         uuid primary key default gen_random_uuid(),
    group_id   uuid not null,
    ym         text not null,                 -- 'YYYY-MM'
    user_id    uuid not null references auth.users (id) on delete cascade,
    amount     numeric(14, 2) not null default 0,
    note       text,
    created_by uuid not null default auth.uid() references auth.users (id) on delete cascade,
    created_at timestamptz not null default now()
);

create index if not exists idx_settlements_group_ym on public.settlements (group_id, ym);

alter table public.settlements enable row level security;

drop policy if exists "settlements_select_group" on public.settlements;
create policy "settlements_select_group" on public.settlements
    for select using (
        group_id = auth.uid() or group_id = public.current_group_id() or public.is_admin()
    );

drop policy if exists "settlements_insert_group" on public.settlements;
create policy "settlements_insert_group" on public.settlements
    for insert with check (
        group_id = auth.uid() or group_id = public.current_group_id()
    );

drop policy if exists "settlements_delete_group" on public.settlements;
create policy "settlements_delete_group" on public.settlements
    for delete using (
        group_id = auth.uid() or group_id = public.current_group_id()
    );

grant select, insert, delete on table public.settlements to authenticated;
