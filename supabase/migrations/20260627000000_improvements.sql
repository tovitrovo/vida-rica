-- =============================================================================
-- Melhorias gerais: admin_emails, updated_at em wishes,
-- status em mentorship_slots e consolidação da função create_wish.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tabela admin_emails: fonte de verdade única para e-mails administrativos.
--    Substitui a lista hardcoded em is_admin() e handle_new_user().
-- -----------------------------------------------------------------------------
create table if not exists public.admin_emails (
    email text primary key
);

-- Popula com os e-mails que antes estavam hardcoded no código.
insert into public.admin_emails (email) values
    ('victortrovo@me.com'),
    ('contato@77estudio.com')
on conflict do nothing;

-- Apenas admins podem ler/escrever a tabela.
alter table public.admin_emails enable row level security;

create policy "admin_emails_select" on public.admin_emails
    for select using (public.is_admin());

create policy "admin_emails_insert" on public.admin_emails
    for insert with check (public.is_admin());

create policy "admin_emails_delete" on public.admin_emails
    for delete using (public.is_admin());

-- Atualiza is_admin() para consultar a tabela.
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

-- Atualiza a trigger de novo usuário para usar a tabela.
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
-- 2. Coluna updated_at em wishes para rastreio de alterações.
-- -----------------------------------------------------------------------------
alter table public.wishes
    add column if not exists updated_at timestamptz not null default now();

-- Trigger para manter updated_at automático.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists wishes_updated_at on public.wishes;
create trigger wishes_updated_at
    before update on public.wishes
    for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- 3. Coluna status em mentorship_slots para substituir o booleano is_booked
--    e permitir status futuros (completed, cancelled).
-- -----------------------------------------------------------------------------
alter table public.mentorship_slots
    add column if not exists slot_status text not null default 'available'
    check (slot_status in ('available', 'booked', 'completed', 'cancelled'));

-- Sincroniza slot_status com o valor atual de is_booked.
update public.mentorship_slots
set slot_status = case when is_booked then 'booked' else 'available' end;

-- Trigger que mantém is_booked em sincronia com slot_status (backward compat).
create or replace function public.sync_slot_booked()
returns trigger
language plpgsql
as $$
begin
    new.is_booked := (new.slot_status = 'booked');
    return new;
end;
$$;

drop trigger if exists mentorship_slots_sync_booked on public.mentorship_slots;
create trigger mentorship_slots_sync_booked
    before update on public.mentorship_slots
    for each row execute function public.sync_slot_booked();
