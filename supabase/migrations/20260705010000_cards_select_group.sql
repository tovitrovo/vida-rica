-- ============================================================================
-- Corrige a soma do "dinheiro em conta" (saldo inicial) para casais/trisais.
--
-- cards.cards_select_own só permitia auth.uid() = user_id, então a página de
-- Metas (fetchGoalsProjection, no front-end) buscava cards.initial_balance de
-- todos os membros do grupo, mas o RLS silenciosamente descartava as linhas
-- do(s) parceiro(s) — a soma exibida refletia só a própria conta do usuário
-- logado, nunca a do grupo inteiro.
-- ============================================================================

create or replace function public.is_group_member(target_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1
        from public.profiles me
        join public.profiles target on target.id = target_user
        where me.id = auth.uid()
          and coalesce(target.group_id, target.id) = coalesce(me.group_id, me.id)
    );
$$;

revoke execute on function public.is_group_member(uuid) from public, anon;
grant execute on function public.is_group_member(uuid) to authenticated;

drop policy if exists "cards_select_own" on public.cards;
drop policy if exists "cards_select_group" on public.cards;
create policy "cards_select_group" on public.cards
    for select using (
        auth.uid() = user_id
        or public.is_group_member(user_id)
    );
