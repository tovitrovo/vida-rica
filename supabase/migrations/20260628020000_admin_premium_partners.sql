-- =============================================================================
-- Promove cagchinigo@hotmail.com e victortrovo@me.com a administradores,
-- garante que tenham conta premium e estende o premium a todos os parceiros
-- vinculados a eles (mesmo group_id).
--
-- Esta migration é AUTOSSUFICIENTE e idempotente: ela mesma garante a
-- existência da tabela public.admin_emails e que is_admin()/handle_new_user()
-- a consultem, caso a migration 20260627000000_improvements.sql ainda não
-- tenha sido aplicada no banco.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tabela admin_emails: fonte de verdade única dos e-mails administrativos.
-- -----------------------------------------------------------------------------
create table if not exists public.admin_emails (
    email text primary key
);

alter table public.admin_emails enable row level security;

-- -----------------------------------------------------------------------------
-- 2. is_admin(): true se o e-mail do JWT estiver em admin_emails.
--    Definido ANTES das policies que dependem dela.
-- -----------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.admin_emails
        where email = lower(auth.jwt() ->> 'email')
    );
$$;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;

-- Apenas admins leem/escrevem a tabela.
drop policy if exists "admin_emails_select" on public.admin_emails;
create policy "admin_emails_select" on public.admin_emails
    for select using (public.is_admin());

drop policy if exists "admin_emails_insert" on public.admin_emails;
create policy "admin_emails_insert" on public.admin_emails
    for insert with check (public.is_admin());

drop policy if exists "admin_emails_delete" on public.admin_emails;
create policy "admin_emails_delete" on public.admin_emails
    for delete using (public.is_admin());

-- -----------------------------------------------------------------------------
-- 3. handle_new_user(): novos cadastros com e-mail admin já nascem 'admin'.
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    user_role text;
begin
    select case when exists (
        select 1 from public.admin_emails where email = lower(new.email)
    ) then 'admin' else 'client' end into user_role;

    insert into public.profiles (id, email, full_name, whatsapp, role, group_id)
    values (
        new.id,
        new.email,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        coalesce(new.raw_user_meta_data->>'whatsapp', ''),
        user_role,
        new.id
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Registra os administradores (e-mails sempre em minúsculas).
-- -----------------------------------------------------------------------------
insert into public.admin_emails (email) values
    ('cagchinigo@hotmail.com'),
    ('victortrovo@me.com')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 5. Reconcilia perfis JÁ existentes (a trigger só atua em novos cadastros).
--    5.1. Garante o papel 'admin'.
-- -----------------------------------------------------------------------------
update public.profiles
set role = 'admin'
where lower(email) in (select email from public.admin_emails)
  and role is distinct from 'admin';

--    5.2. Garante conta premium para os próprios administradores.
update public.profiles
set is_premium = true
where lower(email) in (select email from public.admin_emails)
  and is_premium is distinct from true;

--    5.3. Estende o premium a todos os parceiros vinculados aos admins,
--         isto é, qualquer perfil que compartilhe o group_id de um admin.
update public.profiles
set is_premium = true
where is_premium is distinct from true
  and group_id is not null
  and group_id in (
      select group_id
      from public.profiles
      where lower(email) in (select email from public.admin_emails)
        and group_id is not null
  );
