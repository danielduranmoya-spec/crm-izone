-- CRM Bodas IZONE · esquema para Supabase
-- Todo vive en el esquema public de un proyecto propio (crm-izone), sin tocar otros proyectos.

create extension if not exists pgcrypto;

-- ---------- tablas ----------
create table if not exists public.roles (
  id text primary key,
  nombre text not null,
  secciones text[] not null default '{}',
  orden int not null default 0
);

create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  nombre text not null,
  rol text not null references public.roles(id),
  activo boolean not null default true,
  temporal boolean not null default false,
  valido_desde timestamptz,
  valido_hasta timestamptz,
  revocado boolean not null default false,
  revocado_por text,
  revocado_el timestamptz,
  creado timestamptz not null default now(),
  creado_por text,
  constraint temporal_con_horario check (not temporal or (valido_desde is not null and valido_hasta is not null and valido_hasta > valido_desde)),
  constraint temporal_no_admin check (not (temporal and rol = 'admin'))
);

create table if not exists public.accesos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  tipo text not null check (tipo in ('usuario','temporal','fallido')),
  nombre text, email text, rol text, rol_nombre text,
  entrada timestamptz not null default now(),
  ultimo timestamptz not null default now(),
  salida timestamptz,
  motivo text default '',
  dispositivo text default ''
);
create index if not exists accesos_entrada_idx on public.accesos (entrada desc);

create table if not exists public.ajustes (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  actualizado timestamptz not null default now()
);

create table if not exists public.bodas (
  id text primary key,
  data jsonb not null,
  actualizado timestamptz not null default now()
);

-- presupuesto, pagos y contrato van aparte para que solo los vea quien tenga permiso «economico»
create table if not exists public.bodas_economico (
  boda_id text primary key references public.bodas(id) on delete cascade,
  data jsonb not null,
  actualizado timestamptz not null default now()
);

-- ---------- funciones de permisos (las evalúa el servidor con su propio reloj) ----------
create or replace function public.perfil_valido(p public.perfiles) returns boolean
language sql stable as $$
  select p.id is not null and p.activo and not p.revocado
     and (not p.temporal or (now() >= p.valido_desde and now() < p.valido_hasta));
$$;

create or replace function public.yo_valido() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.perfil_valido(p) from public.perfiles p where p.id = auth.uid()), false);
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.perfil_valido(p) and p.rol = 'admin' and not p.temporal from public.perfiles p where p.id = auth.uid()), false);
$$;

create or replace function public.puede(seccion text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.es_admin() or coalesce((
    select public.perfil_valido(p) and seccion = any(r.secciones)
    from public.perfiles p join public.roles r on r.id = p.rol
    where p.id = auth.uid()), false);
$$;

-- estado de la sesión actual, con la hora del servidor
create or replace function public.mi_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.perfiles; motivo text;
begin
  select * into p from public.perfiles where id = auth.uid();
  if p.id is null then return jsonb_build_object('ok', false, 'motivo', 'Este usuario no tiene acceso al CRM', 'ahora', now()); end if;
  if not p.activo then motivo := 'Cuenta desactivada por un administrador';
  elsif p.revocado then motivo := 'Acceso temporal revocado por un administrador';
  elsif p.temporal and now() < p.valido_desde then motivo := 'Este acceso temporal se activa el ' || to_char(p.valido_desde at time zone 'Europe/Madrid', 'DD/MM/YYYY "a las" HH24:MI');
  elsif p.temporal and now() >= p.valido_hasta then motivo := 'La contraseña temporal caducó';
  end if;
  return jsonb_build_object('ok', motivo is null, 'motivo', coalesce(motivo, ''), 'ahora', now(), 'perfil', to_jsonb(p));
end $$;

-- ---------- historial de accesos ----------
create or replace function public.registrar_entrada(dispositivo text, motivo text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.perfiles; nuevo uuid;
begin
  select * into p from public.perfiles where id = auth.uid();
  if p.id is null or not public.perfil_valido(p) then raise exception 'sin acceso'; end if;
  insert into public.accesos (user_id, tipo, nombre, email, rol, rol_nombre, dispositivo, motivo)
  values (p.id, case when p.temporal then 'temporal' else 'usuario' end, p.nombre, p.email, p.rol,
          (select nombre from public.roles where id = p.rol), left(dispositivo, 80), left(coalesce(motivo, ''), 120))
  returning id into nuevo;
  return nuevo;
end $$;

create or replace function public.registrar_latido(acceso uuid) returns void
language sql security definer set search_path = public as $$
  update public.accesos set ultimo = now(), salida = null, motivo = case when motivo like 'Cerró la pestaña%' then '' else motivo end
  where id = acceso and user_id = auth.uid();
$$;

create or replace function public.registrar_salida(acceso uuid, motivo text) returns void
language sql security definer set search_path = public as $$
  update public.accesos set salida = now(), ultimo = now(), motivo = left(registrar_salida.motivo, 120)
  where id = acceso and user_id = auth.uid() and salida is null;
$$;

-- intentos fallidos (se puede llamar sin sesión). Límite simple para evitar abusos.
create or replace function public.registrar_fallo(email text, motivo text, dispositivo text) returns void
language plpgsql security definer set search_path = public as $$
declare p public.perfiles;
begin
  if (select count(*) from public.accesos where tipo = 'fallido' and entrada > now() - interval '1 minute') > 30 then return; end if;
  select * into p from public.perfiles where lower(perfiles.email) = lower(registrar_fallo.email);
  insert into public.accesos (user_id, tipo, nombre, email, rol, rol_nombre, salida, motivo, dispositivo)
  values (p.id, 'fallido', p.nombre, left(lower(registrar_fallo.email), 120), p.rol, (select nombre from public.roles where id = p.rol), now(), left(motivo, 120), left(dispositivo, 80));
end $$;

-- ¿hay ya algún usuario? (para mostrar la pantalla de primer administrador)
create or replace function public.hay_usuarios() returns boolean
language sql stable security definer set search_path = public as $$ select exists (select 1 from public.perfiles); $$;

-- máximo 3 administradores activos y siempre al menos 1
create or replace function public.control_admins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.perfiles where rol = 'admin' and activo and not temporal) > 3 then
    raise exception 'Ya hay 3 administradores, que es el máximo';
  end if;
  if (select count(*) from public.perfiles) > 0 and (select count(*) from public.perfiles where rol = 'admin' and activo and not temporal) = 0 then
    raise exception 'Tiene que quedar al menos un administrador activo';
  end if;
  return null;
end $$;
drop trigger if exists control_admins on public.perfiles;
create constraint trigger control_admins after insert or update or delete on public.perfiles
  deferrable initially immediate for each row execute function public.control_admins();

-- ---------- seguridad por filas ----------
alter table public.roles enable row level security;
alter table public.perfiles enable row level security;
alter table public.accesos enable row level security;
alter table public.ajustes enable row level security;
alter table public.bodas enable row level security;
alter table public.bodas_economico enable row level security;

drop policy if exists roles_leer on public.roles;
create policy roles_leer on public.roles for select to authenticated using (public.yo_valido());
drop policy if exists roles_admin on public.roles;
create policy roles_admin on public.roles for all to authenticated using (public.es_admin()) with check (public.es_admin() and id <> 'admin');

drop policy if exists perfiles_leer on public.perfiles;
create policy perfiles_leer on public.perfiles for select to authenticated using (id = auth.uid() or public.es_admin());
drop policy if exists perfiles_admin_editar on public.perfiles;
create policy perfiles_admin_editar on public.perfiles for update to authenticated using (public.es_admin()) with check (public.es_admin());
-- altas y bajas de usuarios solo desde la función «admin-usuarios» (clave de servicio)

drop policy if exists accesos_admin on public.accesos;
create policy accesos_admin on public.accesos for select to authenticated using (public.es_admin());

drop policy if exists ajustes_leer on public.ajustes;
create policy ajustes_leer on public.ajustes for select to authenticated using (public.yo_valido());
drop policy if exists ajustes_escribir on public.ajustes;
create policy ajustes_escribir on public.ajustes for insert to authenticated with check (public.puede('ajustes'));
drop policy if exists ajustes_actualizar on public.ajustes;
create policy ajustes_actualizar on public.ajustes for update to authenticated using (public.puede('ajustes')) with check (public.puede('ajustes'));

drop policy if exists bodas_leer on public.bodas;
create policy bodas_leer on public.bodas for select to authenticated
  using (public.puede('bodas') or public.puede('calendario') or public.puede('panel') or public.puede('estadisticas'));
drop policy if exists bodas_crear on public.bodas;
create policy bodas_crear on public.bodas for insert to authenticated with check (public.puede('bodas'));
drop policy if exists bodas_editar on public.bodas;
create policy bodas_editar on public.bodas for update to authenticated using (public.puede('bodas')) with check (public.puede('bodas'));
drop policy if exists bodas_borrar on public.bodas;
create policy bodas_borrar on public.bodas for delete to authenticated using (public.puede('bodas'));

drop policy if exists eco_todo on public.bodas_economico;
create policy eco_todo on public.bodas_economico for all to authenticated using (public.puede('economico')) with check (public.puede('economico'));

-- permisos de ejecución
revoke all on function public.registrar_fallo(text, text, text) from public;
grant execute on function public.registrar_fallo(text, text, text) to anon, authenticated;
grant execute on function public.hay_usuarios() to anon, authenticated;
grant execute on function public.mi_estado(), public.registrar_entrada(text, text), public.registrar_latido(uuid), public.registrar_salida(uuid, text), public.puede(text), public.es_admin(), public.yo_valido() to authenticated;

-- ---------- datos iniciales ----------
insert into public.roles (id, nombre, secciones, orden) values
  ('admin', 'Administrador', '{panel,bodas,calendario,estadisticas,economico,ajustes}', 0),
  ('coordinacion', 'Coordinación', '{panel,bodas,calendario,estadisticas,economico}', 1),
  ('dj', 'DJ', '{panel,bodas,calendario}', 2),
  ('auxiliar', 'Auxiliar', '{bodas,calendario}', 3)
on conflict (id) do nothing;

-- tiempo real para que todo el equipo vea los cambios al momento
do $$ begin
  begin alter publication supabase_realtime add table public.bodas; exception when others then null; end;
  begin alter publication supabase_realtime add table public.bodas_economico; exception when others then null; end;
  begin alter publication supabase_realtime add table public.ajustes; exception when others then null; end;
  begin alter publication supabase_realtime add table public.perfiles; exception when others then null; end;
  begin alter publication supabase_realtime add table public.roles; exception when others then null; end;
end $$;
