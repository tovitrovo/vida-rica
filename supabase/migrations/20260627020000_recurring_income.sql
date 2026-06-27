-- ============================================================================
-- Generaliza recurring_fixed para também suportar RENDA recorrente (salário).
-- type = 'fixed'  → gasto fixo recorrente (saída)
-- type = 'income' → salário / renda fixa recorrente (entrada)
-- ----------------------------------------------------------------------------
-- `alter table if exists` garante que rode mesmo se a tabela ainda não existir
-- (a migração que a cria roda antes, por ordem de timestamp).
-- ============================================================================

alter table if exists public.recurring_fixed
    add column if not exists type text not null default 'fixed';

do $$
begin
    if exists (select 1 from information_schema.tables
               where table_schema = 'public' and table_name = 'recurring_fixed')
       and not exists (select 1 from pg_constraint where conname = 'recurring_fixed_type_chk')
    then
        alter table public.recurring_fixed
            add constraint recurring_fixed_type_chk check (type in ('income', 'fixed'));
    end if;
end $$;
