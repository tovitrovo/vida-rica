-- =============================================================================
-- Promove cagchinigo@hotmail.com e victortrovo@me.com a administradores,
-- garante que tenham conta premium e estende o premium a todos os parceiros
-- vinculados a eles (mesmo group_id).
--
-- A função is_admin() e a trigger handle_new_user() já consultam a tabela
-- public.admin_emails (ver 20260627000000_improvements.sql), então basta
-- registrar os e-mails ali e reconciliar os perfis já existentes.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Fonte de verdade dos administradores. E-mails sempre em minúsculas para
--    casar com lower(auth.jwt() ->> 'email') usado em is_admin().
-- -----------------------------------------------------------------------------
insert into public.admin_emails (email) values
    ('cagchinigo@hotmail.com'),
    ('victortrovo@me.com')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 2. Reconcilia perfis JÁ existentes (a trigger só atua em novos cadastros).
--    2.1. Garante o papel 'admin'.
-- -----------------------------------------------------------------------------
update public.profiles
set role = 'admin'
where lower(email) in (select email from public.admin_emails)
  and role is distinct from 'admin';

-- -----------------------------------------------------------------------------
--    2.2. Garante conta premium para os próprios administradores.
-- -----------------------------------------------------------------------------
update public.profiles
set is_premium = true
where lower(email) in (select email from public.admin_emails)
  and is_premium is distinct from true;

-- -----------------------------------------------------------------------------
--    2.3. Estende o premium a todos os parceiros vinculados aos admins,
--         isto é, qualquer perfil que compartilhe o group_id de um admin.
-- -----------------------------------------------------------------------------
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
