-- =============================================================================
-- Raio-X financeiro do primeiro acesso: saldo em conta, dívidas e investimentos.
-- -----------------------------------------------------------------------------
-- 1. cards ganha um retrato do saldo informado no cadastro (não é saldo vivo).
-- 2. recurring_fixed ganha debt_category para marcar dívidas recorrentes
--    (empréstimo/financiamento/consórcio) sem sair do fluxo normal de gasto
--    fixo — continuam contando no pilar "Fixos" do dashboard.
-- 3. Tabela nova debts, só para dívidas pontuais (sem recorrência mensal).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. cards: saldo informado no cadastro (conta corrente).
-- -----------------------------------------------------------------------------
alter table public.cards add column if not exists initial_balance    numeric(14, 2);
alter table public.cards add column if not exists initial_balance_at timestamptz;

-- -----------------------------------------------------------------------------
-- 2. recurring_fixed: marcador de dívida recorrente.
-- -----------------------------------------------------------------------------
alter table public.recurring_fixed add column if not exists debt_category text;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'recurring_fixed_debt_category_chk') then
        alter table public.recurring_fixed
            add constraint recurring_fixed_debt_category_chk
            check (debt_category is null or debt_category in ('loan', 'financing', 'consortium'));
    end if;
end $$;

-- -----------------------------------------------------------------------------
-- 3. debts: dívidas pontuais (um boleto, uma conta atrasada) sem cadência
--    mensal — não cabem em recurring_fixed nem em transactions (que são
--    sempre lançamentos "deste mês").
-- -----------------------------------------------------------------------------
create table if not exists public.debts (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    group_id    uuid not null,
    description text not null,
    amount      numeric(14, 2) not null default 0,
    due_date    date,
    status      text not null default 'pending',
    created_at  timestamptz not null default now()
);

-- Autocorreção de schema (idempotência), mesmo padrão das demais tabelas.
alter table public.debts add column if not exists user_id     uuid references auth.users (id) on delete cascade;
alter table public.debts add column if not exists group_id    uuid;
alter table public.debts add column if not exists description text;
alter table public.debts add column if not exists amount      numeric(14, 2) not null default 0;
alter table public.debts add column if not exists due_date    date;
alter table public.debts add column if not exists status      text not null default 'pending';
alter table public.debts add column if not exists created_at  timestamptz not null default now();

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'debts_amount_chk') then
        alter table public.debts add constraint debts_amount_chk check (amount >= 0);
    end if;
    if not exists (select 1 from pg_constraint where conname = 'debts_status_chk') then
        alter table public.debts add constraint debts_status_chk check (status in ('pending', 'paid'));
    end if;
end $$;

create index if not exists idx_debts_user_id  on public.debts (user_id);
create index if not exists idx_debts_group_id on public.debts (group_id);

alter table public.debts enable row level security;

drop policy if exists "debts_select_group" on public.debts;
create policy "debts_select_group" on public.debts
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

drop policy if exists "debts_insert_own" on public.debts;
create policy "debts_insert_own" on public.debts
    for insert with check (auth.uid() = user_id);

-- Atualização (ex.: marcar como paga) liberada para o grupo, como recurring_fixed.
drop policy if exists "debts_update_group" on public.debts;
create policy "debts_update_group" on public.debts
    for update using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    ) with check (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "debts_delete_own" on public.debts;
create policy "debts_delete_own" on public.debts
    for delete using (auth.uid() = user_id);

grant select, insert, update, delete on table public.debts to authenticated;
grant all privileges on table public.debts to service_role;
