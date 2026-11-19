-- 19/11/2026: durante una reunión en curso también los administradores necesitan ser participantes
-- y haber introducido la contraseña de la reunión. Quien crea la reunión se añade siempre como participante.
create or replace function public.reunion_bloquea(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.reuniones m where not m.cancelada and now() >= m.desde and now() < m.hasta)
     and not exists (select 1 from public.reuniones m join public.reunion_asistencia a on a.reunion_id = m.id and a.user_id = uid
                     where not m.cancelada and now() >= m.desde and now() < m.hasta and uid = any(m.participantes));
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.perfil_valido(p) and p.rol = 'admin' and not p.temporal and not public.reunion_bloquea(p.id)
                   from public.perfiles p where p.id = auth.uid()), false);
$$;
