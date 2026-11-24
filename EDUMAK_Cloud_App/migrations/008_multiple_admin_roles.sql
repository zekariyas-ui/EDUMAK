-- EDUMAK migration 008: multiple administrator roles and controlled role management.
-- Apply after migrations 001-007. Existing student/admin accounts are preserved.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('student','admin','super_admin'));

create or replace function public.is_edumak_admin()
returns boolean
language sql stable security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid())
      and role in ('admin','super_admin')
  );
$$;

-- Only a Super Admin (or trusted SQL run with auth.uid() = NULL) may change roles.
create or replace function public.protect_edumak_role()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  if new.role is distinct from old.role
     and (select auth.uid()) is not null
     and not exists (
       select 1 from public.profiles
       where id = (select auth.uid()) and role = 'super_admin'
     ) then
    raise exception 'Only a Super Admin can change account roles'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create table if not exists public.admin_role_audit (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  target_id uuid references public.profiles(id) on delete set null,
  old_role text not null,
  new_role text not null,
  changed_at timestamptz not null default now()
);
alter table public.admin_role_audit enable row level security;
revoke all on table public.admin_role_audit from public, anon, authenticated;

create or replace function public.admin_set_user_role(
  p_user_id uuid,
  p_role text
)
returns void
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_actor uuid;
  v_old_role text;
  v_super_count integer;
begin
  v_actor := (select auth.uid());
  if v_actor is null or not exists (
    select 1 from public.profiles
    where id = v_actor and role = 'super_admin'
  ) then
    raise exception 'Super Admin access required' using errcode = '42501';
  end if;

  if p_role not in ('student','admin','super_admin') then
    raise exception 'Invalid account role';
  end if;
  if p_user_id is null then
    raise exception 'Choose an account';
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot change your own role';
  end if;

  select role into v_old_role
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Account not found';
  end if;
  if v_old_role = p_role then
    return;
  end if;

  if v_old_role = 'super_admin' and p_role <> 'super_admin' then
    select count(*) into v_super_count
    from public.profiles where role = 'super_admin';
    if v_super_count <= 1 then
      raise exception 'EDUMAK must always have at least one Super Admin';
    end if;
  end if;

  update public.profiles set role = p_role where id = p_user_id;
  insert into public.admin_role_audit(actor_id,target_id,old_role,new_role)
  values (v_actor,p_user_id,v_old_role,p_role);
end;
$$;

revoke all on function public.admin_set_user_role(uuid,text) from public, anon;
grant execute on function public.admin_set_user_role(uuid,text) to authenticated;

insert into public.edumak_schema_migrations(version, notes)
values ('008_multiple_admin_roles', 'add Super Admin role, protected role-management RPC, and role-change audit log')
on conflict (version) do nothing;
