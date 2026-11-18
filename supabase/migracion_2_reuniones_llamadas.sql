-- Mejoras 18/11/2026: reuniones con acceso restringido, registro de llamadas y enlace con Google Calendar

-- ---------- reuniones ----------
create table if not exists public.reuniones (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  desde timestamptz not null,
  hasta timestamptz not null,
  clave text not null,
  participantes uuid[] not null default '{}',
  notas text not null default '',
  cancelada boolean not null default false,
  cancelada_el timestamptz,
  creado timestamptz not null default now(),
  creado_por text not null default '',
  constraint reunion_horario check (hasta > desde),
  constraint reunion_clave check (length(clave) >= 6)
);
create table if not exists public.reunion_asistencia (
  reunion_id uuid not null references public.reuniones(id) on delete cascade,
  user_id uuid not null,
  nombre text not null default '',
  entrada timestamptz not null default now(),
  primary key (reunion_id, user_id)
);
alter table public.reuniones enable row level security;
alter table public.reunion_asistencia enable row level security;

-- ¿Una reunión en curso impide el acceso a este usuario? (los administradores nunca quedan bloqueados)
create or replace function public.reunion_bloquea(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.reuniones m where not m.cancelada and now() >= m.desde and now() < m.hasta)
     and not exists (select 1 from public.perfiles p where p.id = uid and p.rol = 'admin' and not p.temporal)
     and not exists (select 1 from public.reuniones m join public.reunion_asistencia a on a.reunion_id = m.id and a.user_id = uid
                     where not m.cancelada and now() >= m.desde and now() < m.hasta and uid = any(m.participantes));
$$;

create or replace function public.yo_valido() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.perfil_valido(p) and not public.reunion_bloquea(p.id) from public.perfiles p where p.id = auth.uid()), false);
$$;

create or replace function public.puede(seccion text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.es_admin() or coalesce((
    select public.perfil_valido(p) and not public.reunion_bloquea(p.id) and seccion = any(r.secciones)
    from public.perfiles p join public.roles r on r.id = p.rol
    where p.id = auth.uid()), false);
$$;

create or replace function public.mi_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.perfiles; motivo text; m public.reuniones; reunion jsonb;
begin
  select * into p from public.perfiles where id = auth.uid();
  if p.id is null then return jsonb_build_object('ok', false, 'motivo', 'Este usuario no tiene acceso al CRM', 'ahora', now()); end if;
  if not p.activo then motivo := 'Cuenta desactivada por un administrador';
  elsif p.revocado then motivo := 'Acceso temporal revocado por un administrador';
  elsif p.temporal and now() < p.valido_desde then motivo := 'Este acceso temporal se activa el ' || to_char(p.valido_desde at time zone 'Europe/Madrid', 'DD/MM/YYYY "a las" HH24:MI');
  elsif p.temporal and now() >= p.valido_hasta then motivo := 'La contraseña temporal caducó';
  end if;
  if motivo is null and public.reunion_bloquea(p.id) then
    select * into m from public.reuniones r where not r.cancelada and now() >= r.desde and now() < r.hasta and p.id = any(r.participantes)
      and not exists (select 1 from public.reunion_asistencia a where a.reunion_id = r.id and a.user_id = p.id)
      order by r.desde limit 1;
    if m.id is not null then
      reunion := jsonb_build_object('id', m.id, 'titulo', m.titulo, 'desde', m.desde, 'hasta', m.hasta, 'pendiente', true);
    else
      select * into m from public.reuniones r where not r.cancelada and now() >= r.desde and now() < r.hasta order by r.hasta desc limit 1;
      motivo := 'Hay una reunión en curso hasta las ' || to_char(m.hasta at time zone 'Europe/Madrid', 'HH24:MI') || '. Solo pueden entrar sus participantes';
    end if;
  end if;
  return jsonb_build_object('ok', motivo is null, 'motivo', coalesce(motivo, ''), 'ahora', now(), 'perfil', to_jsonb(p), 'reunion', reunion);
end $$;

-- Un participante introduce la contraseña de la reunión en curso
create or replace function public.entrar_reunion(clave text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.perfiles; m public.reuniones;
begin
  select * into p from public.perfiles where id = auth.uid();
  if p.id is null or not public.perfil_valido(p) then return jsonb_build_object('ok', false, 'motivo', 'Sin acceso'); end if;
  if (select count(*) from public.accesos a where a.user_id = p.id and a.tipo = 'fallido' and a.motivo = 'Contraseña de reunión incorrecta' and a.entrada > now() - interval '10 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'motivo', 'Demasiados intentos. Espera unos minutos.');
  end if;
  select * into m from public.reuniones r where not r.cancelada and now() >= r.desde and now() < r.hasta and p.id = any(r.participantes) and r.clave = entrar_reunion.clave order by r.desde limit 1;
  if m.id is null then
    insert into public.accesos (user_id, tipo, nombre, email, rol, rol_nombre, salida, motivo)
    values (p.id, 'fallido', p.nombre, p.email, p.rol, (select nombre from public.roles where id = p.rol), now(), 'Contraseña de reunión incorrecta');
    return jsonb_build_object('ok', false, 'motivo', 'La contraseña de la reunión no es correcta.');
  end if;
  insert into public.reunion_asistencia (reunion_id, user_id, nombre) values (m.id, p.id, p.nombre) on conflict do nothing;
  return jsonb_build_object('ok', true, 'titulo', m.titulo);
end $$;

drop policy if exists reuniones_admin on public.reuniones;
create policy reuniones_admin on public.reuniones for all to authenticated using (public.es_admin()) with check (public.es_admin());
drop policy if exists asistencia_admin on public.reunion_asistencia;
create policy asistencia_admin on public.reunion_asistencia for select to authenticated using (public.es_admin());

-- ---------- registro de llamadas ----------
create table if not exists public.llamadas (
  id text primary key,
  data jsonb not null default '{}',
  creado timestamptz not null default now()
);
alter table public.llamadas enable row level security;
drop policy if exists llamadas_todo on public.llamadas;
create policy llamadas_todo on public.llamadas for all to authenticated using (public.puede('llamadas')) with check (public.puede('llamadas'));
update public.roles set secciones = array_append(secciones, 'llamadas') where id = 'coordinacion' and not ('llamadas' = any(secciones));

-- ---------- secretos (solo administradores): token del calendario para Google ----------
create table if not exists public.secretos (id text primary key, valor text not null);
alter table public.secretos enable row level security;
drop policy if exists secretos_admin on public.secretos;
create policy secretos_admin on public.secretos for all to authenticated using (public.es_admin()) with check (public.es_admin());

-- ---------- permisos ----------
grant select, insert, update, delete on public.reuniones, public.reunion_asistencia, public.llamadas, public.secretos to authenticated;
revoke all on public.reuniones, public.reunion_asistencia, public.llamadas, public.secretos from anon;
revoke execute on function public.reunion_bloquea(uuid) from public, anon, authenticated;
revoke execute on function public.entrar_reunion(text) from public, anon;
grant execute on function public.entrar_reunion(text) to authenticated;

alter publication supabase_realtime add table public.llamadas, public.reuniones;
