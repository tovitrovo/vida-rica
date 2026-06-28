-- ============================================================================
-- Adiciona coluna is_shared em recurring_fixed
-- Gastos marcados como is_shared = false só aparecem para o próprio dono,
-- não para os outros membros do grupo (parceiros que entraram por convite).
-- ============================================================================

alter table if exists public.recurring_fixed
    add column if not exists is_shared boolean not null default true;
