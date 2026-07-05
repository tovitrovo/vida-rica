-- ============================================================================
-- Permite editar (não só excluir) lançamentos avulsos próprios, para ajustar
-- o valor da fatura do cartão sem precisar lançar gasto a gasto no dia a dia.
-- ============================================================================
drop policy if exists "transactions_update_own" on public.transactions;
create policy "transactions_update_own" on public.transactions
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- A RLS sozinha não basta: sem o GRANT, o Postgres nega o UPDATE antes mesmo
-- de avaliar a policy.
grant update on table public.transactions to authenticated;
