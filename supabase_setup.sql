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

-- O insert do perfil é feito pelo gatilho (security definer); ainda assim
-- liberamos o insert da própria linha como contingência do front-end.
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
    for insert with check (auth.uid() = id);

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
        or group_id = (select p.group_id from public.profiles p where p.id = auth.uid())
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
-- 5. GATILHO DE CRIAÇÃO DE PERFIL
--    Insere automaticamente o usuário em public.profiles após o cadastro.
--    O papel 'admin' é atribuído somente ao e-mail victortrovo@me.com.
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
            when lower(new.email) = 'victortrovo@me.com' then 'admin'
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

-- ============================================================================
-- FIM DO SCRIPT
-- ============================================================================
