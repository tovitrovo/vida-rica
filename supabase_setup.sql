-- ============================================================================
-- VIDA RICA — Plano de Gastos Conscientes com Gestão Estratégica Unificada
-- Script completo de configuração do back-end (Supabase / PostgreSQL)
-- ----------------------------------------------------------------------------
-- Execute este script no SQL Editor do Supabase. Ele cria as tabelas,
-- ativa o RLS (Row Level Security), define as políticas de acesso e o
-- gatilho que cria o perfil automaticamente após o cadastro do usuário.
-- ============================================================================

-- Extensão para geração de UUIDs (já vem habilitada na maioria dos projetos)
create extension if not exists "pgcrypto";

-- ============================================================================
-- 1. TABELA: public.profiles
--    Espelho do auth.users com dados de negócio (papel, premium, parceria).
-- ============================================================================
create table if not exists public.profiles (
    id          uuid primary key references auth.users (id) on delete cascade,
    email       text,
    full_name   text,
    whatsapp    text,
    role        text        not null default 'client',
    is_premium  boolean     not null default false,
    group_id    uuid,                 -- usado para fundir contas (casal / trisal)
    created_at  timestamptz not null default now()
);

-- ============================================================================
-- 2. TABELA: public.cards
--    Cartões / contas bancárias cadastrados por cada usuário.
-- ============================================================================
create table if not exists public.cards (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users (id) on delete cascade,
    name       text not null,                          -- ex: NuBank, Itaú
    type       text not null default 'credit'          -- 'credit' | 'checking'
               check (type in ('credit', 'checking')),
    created_at timestamptz not null default now()
);

-- ============================================================================
-- 3. TABELA: public.transactions
--    Lançamentos dos quatro pilares (renda, fixo, investimento, livre).
-- ============================================================================
create table if not exists public.transactions (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references auth.users (id) on delete cascade,
    group_id            uuid,                          -- consolida extratos da parceria
    type                text not null default 'free'   -- 'income'|'fixed'|'invest'|'free'
                        check (type in ('income', 'fixed', 'invest', 'free')),
    amount              numeric(14, 2) not null default 0,
    description         text,
    card_id             uuid references public.cards (id) on delete set null,
    current_installment int not null default 1,
    total_installments  int not null default 1,
    created_at          timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 3.1. AUTOCORREÇÃO DE SCHEMA (idempotência)
--      Se as tabelas já existiam de versões anteriores com um schema diferente,
--      os CREATE acima foram ignorados. Garantimos aqui que TODAS as colunas
--      existam ANTES de qualquer índice ou política referenciá-las.
-- ----------------------------------------------------------------------------
alter table public.profiles add column if not exists email      text;
alter table public.profiles add column if not exists full_name  text;
alter table public.profiles add column if not exists whatsapp   text;
alter table public.profiles add column if not exists role       text    not null default 'client';
alter table public.profiles add column if not exists is_premium boolean not null default false;
alter table public.profiles add column if not exists group_id   uuid;
alter table public.profiles add column if not exists created_at timestamptz not null default now();

alter table public.cards add column if not exists user_id    uuid references auth.users (id) on delete cascade;
alter table public.cards add column if not exists name       text;
alter table public.cards add column if not exists type       text not null default 'credit';
alter table public.cards add column if not exists created_at timestamptz not null default now();

alter table public.transactions add column if not exists user_id             uuid references auth.users (id) on delete cascade;
alter table public.transactions add column if not exists group_id            uuid;
alter table public.transactions add column if not exists type                text not null default 'free';
alter table public.transactions add column if not exists amount              numeric(14, 2) not null default 0;
alter table public.transactions add column if not exists description         text;
alter table public.transactions add column if not exists card_id             uuid references public.cards (id) on delete set null;
alter table public.transactions add column if not exists current_installment int not null default 1;
alter table public.transactions add column if not exists total_installments  int not null default 1;
alter table public.transactions add column if not exists created_at          timestamptz not null default now();

-- Índices para acelerar as consultas do dashboard
create index if not exists idx_transactions_user_id  on public.transactions (user_id);
create index if not exists idx_transactions_group_id on public.transactions (group_id);
create index if not exists idx_cards_user_id         on public.cards (user_id);

-- ============================================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================================
alter table public.profiles     enable row level security;
alter table public.cards        enable row level security;
alter table public.transactions enable row level security;

-- ---------- POLÍTICAS: profiles ----------
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
    for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
    for update using (auth.uid() = id) with check (auth.uid() = id);
-- NOTA: o RLS controla QUAIS LINHAS, mas não quais colunas. A restrição de
-- coluna (impedir o cliente de alterar role/is_premium) é feita via GRANT de
-- coluna mais abaixo, na seção de GRANTs da Data API.

-- O insert do perfil é feito pelo gatilho (security definer); ainda assim
-- liberamos o insert da própria linha como contingência do front-end.
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
    for insert with check (auth.uid() = id);

-- ============================================================================
-- 4.1.1. FUNÇÃO AUXILIAR: public.current_group_id()
--        Lê o grupo do usuário autenticado com SECURITY DEFINER para evitar
--        recursão de RLS quando políticas de outras tabelas precisam consultar
--        public.profiles.
-- ============================================================================
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

-- ---------- POLÍTICAS: cards ----------
drop policy if exists "cards_select_own" on public.cards;
create policy "cards_select_own" on public.cards
    for select using (auth.uid() = user_id);

drop policy if exists "cards_insert_own" on public.cards;
create policy "cards_insert_own" on public.cards
    for insert with check (auth.uid() = user_id);

drop policy if exists "cards_delete_own" on public.cards;
create policy "cards_delete_own" on public.cards
    for delete using (auth.uid() = user_id);

-- ---------- POLÍTICAS: transactions ----------
-- Leitura: as próprias transações OU as do grupo (parceria) ao qual pertenço.
drop policy if exists "transactions_select_group" on public.transactions;
create policy "transactions_select_group" on public.transactions
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

-- Inserção: só posso lançar movimentações em meu próprio nome.
drop policy if exists "transactions_insert_own" on public.transactions;
create policy "transactions_insert_own" on public.transactions
    for insert with check (auth.uid() = user_id);

-- Exclusão: só posso apagar meus próprios lançamentos.
drop policy if exists "transactions_delete_own" on public.transactions;
create policy "transactions_delete_own" on public.transactions
    for delete using (auth.uid() = user_id);

-- ============================================================================
-- 4.1. FUNÇÃO AUXILIAR: public.is_admin()
--      Retorna true se o e-mail do JWT do chamador for de um administrador.
--      Lê o e-mail direto do token (não da tabela profiles) para evitar
--      recursão de RLS nas políticas de administrador.
-- ============================================================================
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

-- Administradores podem ler todos os perfis (lista de clientes do painel admin).
drop policy if exists "profiles_select_admin" on public.profiles;
create policy "profiles_select_admin" on public.profiles
    for select using (public.is_admin());

-- ============================================================================
-- 4.2. PROTEÇÃO: impedir exclusão de cartão/conta com lançamentos vinculados
--      O front-end mostra o aviso antes, e este trigger garante a regra no banco.
-- ============================================================================
create or replace function public.prevent_card_delete_with_transactions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if old.user_id <> auth.uid() and not public.is_admin() then
        raise exception 'Sem permissão para apagar este cartão ou conta.';
    end if;

    if exists (
        select 1
        from public.transactions t
        where t.card_id = old.id
    ) then
        raise exception 'Não é possível apagar este cartão ou conta porque existem lançamentos vinculados.';
    end if;

    return old;
end;
$$;

drop trigger if exists prevent_card_delete_with_transactions on public.cards;
create trigger prevent_card_delete_with_transactions
    before delete on public.cards
    for each row execute function public.prevent_card_delete_with_transactions();

revoke execute on function public.prevent_card_delete_with_transactions() from public, anon, authenticated;

-- ============================================================================
-- 6. TABELA: public.plan_prices
--    Matriz de preços (configurável pelo admin). 6 combinações de plano.
-- ============================================================================
create table if not exists public.plan_prices (
    account_type    text    not null check (account_type in ('individual', 'couple', 'throuple')),
    with_mentorship boolean not null default false,
    amount          numeric(14, 2) not null default 0,
    updated_at      timestamptz not null default now(),
    primary key (account_type, with_mentorship)
);

-- Seed idempotente dos 6 planos (valores default — ajustáveis no painel admin).
insert into public.plan_prices (account_type, with_mentorship, amount) values
    ('individual', false,  29.90),
    ('individual', true,  149.90),
    ('couple',     false,  49.90),
    ('couple',     true,  199.90),
    ('throuple',   false,  69.90),
    ('throuple',   true,  249.90)
on conflict (account_type, with_mentorship) do nothing;

-- ============================================================================
-- 7. TABELA: public.subscriptions
--    Assinatura recorrente (Mercado Pago preapproval) que libera o acesso.
-- ============================================================================
create table if not exists public.subscriptions (
    id                 uuid primary key default gen_random_uuid(),
    user_id            uuid not null references auth.users (id) on delete cascade,
    group_id           uuid,
    account_type       text not null default 'individual'
                       check (account_type in ('individual', 'couple', 'throuple')),
    with_mentorship    boolean not null default false,
    status             text not null default 'pending'
                       check (status in ('pending', 'active', 'paused', 'cancelled')),
    amount             numeric(14, 2) not null default 0,
    mp_preapproval_id  text,
    current_period_end timestamptz,
    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now()
);

-- ============================================================================
-- 8. TABELA: public.mentorship_slots
--    Horários de disponibilidade criados pelos administradores.
-- ============================================================================
create table if not exists public.mentorship_slots (
    id           uuid primary key default gen_random_uuid(),
    admin_id     uuid not null references auth.users (id) on delete cascade,
    starts_at    timestamptz not null,
    duration_min int not null default 60,
    is_booked    boolean not null default false,
    created_at   timestamptz not null default now()
);

-- ============================================================================
-- 9. TABELA: public.mentorship_bookings
--    Agendamentos de mentoria (1 por mês-calendário; só plano com mentoria).
-- ============================================================================
create table if not exists public.mentorship_bookings (
    id           uuid primary key default gen_random_uuid(),
    slot_id      uuid not null references public.mentorship_slots (id) on delete cascade,
    user_id      uuid not null references auth.users (id) on delete cascade,
    group_id     uuid,
    scheduled_at timestamptz not null,
    status       text not null default 'booked'
                 check (status in ('booked', 'done', 'cancelled')),
    created_at   timestamptz not null default now()
);

-- ============================================================================
-- 10. TABELA: public.wishes
--     Desejos pessoais ou compartilhados do grupo.
-- ============================================================================
create table if not exists public.wishes (
    id          uuid primary key default gen_random_uuid(),
    owner_id    uuid not null references auth.users (id) on delete cascade,
    group_id    uuid,
    title       text not null,
    amount      numeric(14, 2) not null default 0,
    scope       text not null default 'personal' check (scope in ('personal', 'shared')),
    status      text not null default 'open' check (status in ('open', 'achieved', 'cancelled')),
    target_date date,
    created_at  timestamptz not null default now()
);

-- ============================================================================
-- 11. TABELA: public.wish_contributions
--     Aportes feitos a um desejo (inclusive do parceiro num desejo pessoal).
-- ============================================================================
create table if not exists public.wish_contributions (
    id         uuid primary key default gen_random_uuid(),
    wish_id    uuid not null references public.wishes (id) on delete cascade,
    user_id    uuid not null references auth.users (id) on delete cascade,
    amount     numeric(14, 2) not null default 0,
    created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 11.1. AUTOCORREÇÃO DE SCHEMA DAS NOVAS TABELAS (idempotência)
--       Se alguma destas tabelas já existia de uma versão anterior com schema
--       diferente, os CREATE acima foram ignorados. Garantimos aqui que TODAS
--       as colunas existam ANTES de qualquer índice ou política referenciá-las.
-- ----------------------------------------------------------------------------
alter table public.plan_prices add column if not exists account_type    text;
alter table public.plan_prices add column if not exists with_mentorship boolean not null default false;
alter table public.plan_prices add column if not exists amount          numeric(14, 2) not null default 0;
alter table public.plan_prices add column if not exists updated_at      timestamptz not null default now();

alter table public.subscriptions add column if not exists user_id            uuid references auth.users (id) on delete cascade;
alter table public.subscriptions add column if not exists group_id           uuid;
alter table public.subscriptions add column if not exists account_type       text not null default 'individual';
alter table public.subscriptions add column if not exists with_mentorship    boolean not null default false;
alter table public.subscriptions add column if not exists status             text not null default 'pending';
alter table public.subscriptions add column if not exists amount             numeric(14, 2) not null default 0;
alter table public.subscriptions add column if not exists mp_preapproval_id  text;
alter table public.subscriptions add column if not exists current_period_end timestamptz;
alter table public.subscriptions add column if not exists created_at         timestamptz not null default now();
alter table public.subscriptions add column if not exists updated_at         timestamptz not null default now();

alter table public.mentorship_slots add column if not exists admin_id     uuid references auth.users (id) on delete cascade;
alter table public.mentorship_slots add column if not exists starts_at    timestamptz;
alter table public.mentorship_slots add column if not exists duration_min int not null default 60;
alter table public.mentorship_slots add column if not exists is_booked    boolean not null default false;
alter table public.mentorship_slots add column if not exists created_at   timestamptz not null default now();

alter table public.mentorship_bookings add column if not exists slot_id      uuid references public.mentorship_slots (id) on delete cascade;
alter table public.mentorship_bookings add column if not exists user_id      uuid references auth.users (id) on delete cascade;
alter table public.mentorship_bookings add column if not exists group_id     uuid;
alter table public.mentorship_bookings add column if not exists scheduled_at timestamptz;
alter table public.mentorship_bookings add column if not exists status       text not null default 'booked';
alter table public.mentorship_bookings add column if not exists created_at   timestamptz not null default now();

alter table public.wishes add column if not exists owner_id    uuid references auth.users (id) on delete cascade;
alter table public.wishes add column if not exists group_id    uuid;
alter table public.wishes add column if not exists title       text;
alter table public.wishes add column if not exists amount      numeric(14, 2) not null default 0;
alter table public.wishes add column if not exists scope       text not null default 'personal';
alter table public.wishes add column if not exists status      text not null default 'open';
alter table public.wishes add column if not exists target_date date;
alter table public.wishes add column if not exists created_at  timestamptz not null default now();

alter table public.wish_contributions add column if not exists wish_id    uuid references public.wishes (id) on delete cascade;
alter table public.wish_contributions add column if not exists user_id    uuid references auth.users (id) on delete cascade;
alter table public.wish_contributions add column if not exists amount     numeric(14, 2) not null default 0;
alter table public.wish_contributions add column if not exists created_at timestamptz not null default now();

-- Índices de apoio
create index if not exists idx_subscriptions_user_id       on public.subscriptions (user_id);
create index if not exists idx_subscriptions_group_id      on public.subscriptions (group_id);
create unique index if not exists idx_subscriptions_mp_preapproval_id
    on public.subscriptions (mp_preapproval_id)
    where mp_preapproval_id is not null;
create index if not exists idx_mentorship_bookings_user_id on public.mentorship_bookings (user_id);
create unique index if not exists idx_mentorship_slots_admin_starts_at
    on public.mentorship_slots (admin_id, starts_at);
create index if not exists idx_wishes_group_id             on public.wishes (group_id);
create index if not exists idx_wishes_owner_id             on public.wishes (owner_id);
create index if not exists idx_wish_contributions_wish_id  on public.wish_contributions (wish_id);

-- ----------------------------------------------------------------------------
-- 11.2. GRANTS EXPLÍCITOS PARA DATA API
--       Desde 30/05/2026, novos projetos Supabase podem não expor tabelas do
--       schema public automaticamente. Mantemos os GRANTs junto do RLS para que
--       o front-end via supabase-js e as Edge Functions via service_role funcionem.
-- ----------------------------------------------------------------------------
grant usage on schema public to authenticated, service_role;

-- profiles: o UPDATE é restrito por COLUNA. Sem isto, como o RLS já libera a
-- própria linha, o cliente poderia se autopromover alterando role/is_premium.
-- Essas colunas ficam reservadas ao gatilho de cadastro e ao painel (service_role).
grant select, insert on table public.profiles to authenticated;
grant update (full_name, whatsapp, group_id) on table public.profiles to authenticated;
grant select, insert, delete on table public.cards to authenticated;
grant select, insert, delete on table public.transactions to authenticated;
grant select, insert, update on table public.plan_prices to authenticated;
grant select, insert on table public.subscriptions to authenticated;
grant select, insert, update, delete on table public.mentorship_slots to authenticated;
grant select, insert, update on table public.mentorship_bookings to authenticated;
grant select, insert, update, delete on table public.wishes to authenticated;
grant select, insert on table public.wish_contributions to authenticated;

grant all privileges on table public.profiles to service_role;
grant all privileges on table public.cards to service_role;
grant all privileges on table public.transactions to service_role;
grant all privileges on table public.plan_prices to service_role;
grant all privileges on table public.subscriptions to service_role;
grant all privileges on table public.mentorship_slots to service_role;
grant all privileges on table public.mentorship_bookings to service_role;
grant all privileges on table public.wishes to service_role;
grant all privileges on table public.wish_contributions to service_role;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;

-- ============================================================================
-- 12. ROW LEVEL SECURITY DAS NOVAS TABELAS
-- ============================================================================
alter table public.plan_prices         enable row level security;
alter table public.subscriptions       enable row level security;
alter table public.mentorship_slots    enable row level security;
alter table public.mentorship_bookings enable row level security;
alter table public.wishes              enable row level security;
alter table public.wish_contributions  enable row level security;

-- Helper de pertencimento ao grupo (próprio id OU group_id do meu perfil).
-- Usado nas políticas abaixo via subselect direto para manter tudo explícito.

-- ---------- POLÍTICAS: plan_prices ----------
-- Qualquer autenticado lê os preços (tela de planos). Só admin altera.
drop policy if exists "plan_prices_select_all" on public.plan_prices;
create policy "plan_prices_select_all" on public.plan_prices
    for select
    to authenticated
    using (true);

drop policy if exists "plan_prices_update_admin" on public.plan_prices;
create policy "plan_prices_update_admin" on public.plan_prices
    for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "plan_prices_insert_admin" on public.plan_prices;
create policy "plan_prices_insert_admin" on public.plan_prices
    for insert with check (public.is_admin());

-- ---------- POLÍTICAS: subscriptions ----------
-- Leitura: a minha assinatura, a do meu grupo, ou todas (se admin).
drop policy if exists "subscriptions_select_group" on public.subscriptions;
create policy "subscriptions_select_group" on public.subscriptions
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

-- Inserção: só posso criar assinatura em meu próprio nome (contingência;
-- o fluxo normal cria via Edge Function com service role).
drop policy if exists "subscriptions_insert_own" on public.subscriptions;
create policy "subscriptions_insert_own" on public.subscriptions
    for insert with check (auth.uid() = user_id);

-- ---------- POLÍTICAS: mentorship_slots ----------
-- Leitura: qualquer autenticado vê os horários disponíveis. Admin gerencia.
drop policy if exists "mentorship_slots_select_all" on public.mentorship_slots;
create policy "mentorship_slots_select_all" on public.mentorship_slots
    for select
    to authenticated
    using (true);

drop policy if exists "mentorship_slots_admin_all" on public.mentorship_slots;
create policy "mentorship_slots_admin_all" on public.mentorship_slots
    for all using (public.is_admin()) with check (public.is_admin());

-- ---------- POLÍTICAS: mentorship_bookings ----------
drop policy if exists "mentorship_bookings_select_group" on public.mentorship_bookings;
create policy "mentorship_bookings_select_group" on public.mentorship_bookings
    for select using (
        auth.uid() = user_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
        or public.is_admin()
    );

drop policy if exists "mentorship_bookings_insert_own" on public.mentorship_bookings;
create policy "mentorship_bookings_insert_own" on public.mentorship_bookings
    for insert with check (auth.uid() = user_id);

drop policy if exists "mentorship_bookings_update_own" on public.mentorship_bookings;
create policy "mentorship_bookings_update_own" on public.mentorship_bookings
    for update using (auth.uid() = user_id or public.is_admin())
    with check (auth.uid() = user_id or public.is_admin());

-- ---------- POLÍTICAS: wishes ----------
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

-- Atualização: dono OU parceiro do mesmo grupo (para aceitar como compartilhado).
drop policy if exists "wishes_update_group" on public.wishes;
create policy "wishes_update_group" on public.wishes
    for update using (
        auth.uid() = owner_id
        or group_id = auth.uid()
        or group_id = public.current_group_id()
    );

drop policy if exists "wishes_delete_own" on public.wishes;
create policy "wishes_delete_own" on public.wishes
    for delete using (auth.uid() = owner_id);

-- ---------- POLÍTICAS: wish_contributions ----------
-- Leitura: aportes de desejos visíveis ao meu grupo.
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

-- Inserção: aporto em meu próprio nome (em qualquer desejo do meu grupo).
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

-- ============================================================================
-- 13. GATILHO DE AGENDAMENTO DE MENTORIA
--     Ao inserir um booking: valida disponibilidade do horário, impõe o limite
--     de 1 mentoria por mês-calendário no grupo e marca o slot como reservado.
--     Roda como SECURITY DEFINER para poder atualizar mentorship_slots
--     (cuja escrita é restrita ao admin pela RLS).
-- ============================================================================
create or replace function public.handle_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    slot_taken boolean;
    same_month int;
begin
    select is_booked into slot_taken from public.mentorship_slots where id = new.slot_id for update;
    if slot_taken is null then raise exception 'Horário inexistente.'; end if;
    if slot_taken then raise exception 'Este horário já foi reservado.'; end if;

    select count(*) into same_month
        from public.mentorship_bookings b
        where b.status = 'booked'
          and (b.user_id = new.user_id or b.group_id = new.group_id)
          and date_trunc('month', b.scheduled_at) = date_trunc('month', new.scheduled_at);
    if same_month > 0 then raise exception 'Você já tem uma mentoria agendada neste mês.'; end if;

    update public.mentorship_slots set is_booked = true where id = new.slot_id;
    return new;
end;
$$;

drop trigger if exists on_booking_created on public.mentorship_bookings;
create trigger on_booking_created
    before insert on public.mentorship_bookings
    for each row execute function public.handle_new_booking();

revoke execute on function public.handle_new_booking() from public, anon, authenticated;

-- ============================================================================
-- 14. FUNÇÃO: public.join_partner(partner uuid)
--     Vincula o usuário autenticado ao grupo do parceiro, respeitando o limite
--     do plano (casal = 2 pessoas, trisal = 3). SECURITY DEFINER para enxergar
--     os membros e a assinatura do dono mesmo com a RLS ativa.
--     Retorna 'ok' | 'self' | 'full' | 'no_plan'.
-- ============================================================================
create or replace function public.join_partner(partner uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    owner_account text;
    limit_n int;
    current_n int;
begin
    if partner = auth.uid() then return 'self'; end if;

    select account_type into owner_account
        from public.subscriptions
        where user_id = partner
          and status = 'active'
        order by (status = 'active') desc, created_at desc
        limit 1;

    if owner_account is null then return 'no_plan'; end if;

    limit_n := case owner_account when 'throuple' then 3 when 'couple' then 2 else 1 end;

    select count(*) into current_n
        from public.profiles
        where group_id = partner or id = partner;

    if current_n >= limit_n then return 'full'; end if;

    update public.profiles set group_id = partner where id = auth.uid();
    return 'ok';
end;
$$;

revoke execute on function public.join_partner(uuid) from public, anon;
grant execute on function public.join_partner(uuid) to authenticated;

-- ============================================================================
-- 5. GATILHO DE CRIAÇÃO DE PERFIL
--    Insere automaticamente o usuário em public.profiles após o cadastro.
--    O papel 'admin' é atribuído aos e-mails victortrovo@me.com e contato@77estudio.com.
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, email, full_name, whatsapp, role)
    values (
        new.id,
        new.email,
        coalesce(new.raw_user_meta_data ->> 'full_name', ''),
        coalesce(new.raw_user_meta_data ->> 'whatsapp', ''),
        case
            when lower(new.email) in ('victortrovo@me.com', 'contato@77estudio.com') then 'admin'
            else 'client'
        end
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

-- Recria o gatilho de forma idempotente
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ============================================================================
-- FIM DO SCRIPT
-- ============================================================================
