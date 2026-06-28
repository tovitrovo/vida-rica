-- ============================================================================
-- Adiciona coluna `shared` em recurring_fixed
-- ----------------------------------------------------------------------------
-- Indica se o gasto fixo é compartilhado entre os parceiros (true, padrão)
-- ou pertence apenas ao usuário que o criou (false).
-- O convidado pode alterar este flag durante o onboarding de parceria.
-- ============================================================================

alter table public.recurring_fixed
    add column if not exists shared boolean not null default true;
