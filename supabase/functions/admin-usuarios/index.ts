// Alta, baja y cambio de contraseña de empleados del CRM IZONE.
// Solo la pueden usar administradores (se comprueba con su sesión), salvo «bootstrap»,
// que crea el primer administrador y solo funciona mientras no exista ningún usuario.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const emailOk = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: Record<string, any>;
  try { body = await req.json(); } catch { return json({ error: "Petición no válida" }, 400); }
  const accion = String(body.accion || "");

  async function crearUsuario(email: string, password: string, perfil: Record<string, unknown>) {
    const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (error || !data.user) return json({ error: error?.message?.includes("already") ? "Ya existe una cuenta con ese correo" : (error?.message || "No se pudo crear") }, 400);
    const { error: e2 } = await admin.from("perfiles").insert({ id: data.user.id, email, ...perfil });
    if (e2) { await admin.auth.admin.deleteUser(data.user.id); return json({ error: e2.message }, 400); }
    return json({ ok: true, id: data.user.id });
  }

  if (accion === "bootstrap") {
    const { count } = await admin.from("perfiles").select("id", { count: "exact", head: true });
    if ((count ?? 0) > 0) return json({ error: "Ya existe un administrador" }, 403);
    const email = String(body.email || "").trim().toLowerCase(), password = String(body.password || ""), nombre = String(body.nombre || "").trim();
    if (!nombre || !emailOk(email) || password.length < 8) return json({ error: "Datos incompletos" }, 400);
    return crearUsuario(email, password, { nombre, rol: "admin", creado_por: "Configuración inicial" });
  }

  // el resto de acciones exige un administrador con sesión válida
  const auth = req.headers.get("Authorization") || "";
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: esAdmin } = await caller.rpc("es_admin");
  if (esAdmin !== true) return json({ error: "Solo un administrador puede hacer esto" }, 403);
  const { data: yo } = await caller.auth.getUser();
  const { data: miPerfil } = await admin.from("perfiles").select("nombre").eq("id", yo.user!.id).single();

  if (accion === "crear") {
    const email = String(body.email || "").trim().toLowerCase(), password = String(body.password || ""), nombre = String(body.nombre || "").trim(), rol = String(body.rol || "");
    if (!nombre || !emailOk(email) || password.length < 8 || !rol) return json({ error: "Datos incompletos" }, 400);
    const temporal = !!body.temporal;
    const perfil: Record<string, unknown> = { nombre, rol, temporal, creado_por: miPerfil?.nombre || "" };
    if (temporal) {
      const desde = new Date(body.desde), hasta = new Date(body.hasta);
      if (isNaN(+desde) || isNaN(+hasta) || hasta <= desde) return json({ error: "Horario no válido" }, 400);
      if (rol === "admin") return json({ error: "Un acceso temporal no puede ser de administrador" }, 400);
      perfil.valido_desde = desde.toISOString(); perfil.valido_hasta = hasta.toISOString();
    }
    return crearUsuario(email, password, perfil);
  }
  if (accion === "clave") {
    const password = String(body.password || "");
    if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);
    const { error } = await admin.auth.admin.updateUserById(String(body.id), { password });
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }
  if (accion === "borrar") {
    if (String(body.id) === yo.user!.id) return json({ error: "No puedes borrarte a ti mismo" }, 400);
    const { error: e1 } = await admin.from("perfiles").delete().eq("id", String(body.id));
    if (e1) return json({ error: e1.message }, 400);
    const { error } = await admin.auth.admin.deleteUser(String(body.id));
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }
  return json({ error: "Acción desconocida" }, 400);
});
