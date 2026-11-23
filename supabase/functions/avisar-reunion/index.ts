// Envía por correo a los participantes de una reunión su título, horario y contraseña.
// Solo la usa un administrador (aunque la reunión ya esté en curso).
// Proveedor: Resend (secretos RESEND_API_KEY y MAIL_FROM) o cualquier SMTP por SSL
// (secretos SMTP_HOST, SMTP_PORT=465, SMTP_USER, SMTP_PASS y MAIL_FROM opcional).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const CRM = Deno.env.get("CRM_URL") || "https://danielduranmoya-spec.github.io/crm-izone/";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
  const { data: u } = await caller.auth.getUser();
  if (!u?.user) return json({ error: "Sin sesión" }, 401);
  const { data: yo } = await admin.from("perfiles").select("nombre, email, rol, activo, revocado, temporal").eq("id", u.user.id).single();
  if (!yo || yo.rol !== "admin" || !yo.activo || yo.revocado || yo.temporal) return json({ error: "Solo un administrador puede hacer esto" }, 403);

  let body: Record<string, unknown>; try { body = await req.json(); } catch { return json({ error: "Petición no válida" }, 400); }
  const { data: m } = await admin.from("reuniones").select("*").eq("id", String(body.reunion || "")).single();
  if (!m) return json({ error: "No encuentro la reunión" }, 404);
  if (m.cancelada) return json({ error: "La reunión está cancelada" }, 400);
  const { data: gente } = await admin.from("perfiles").select("nombre, email").in("id", m.participantes);
  const destinos = (gente || []).filter(p => p.email);
  if (!destinos.length) return json({ error: "Los participantes no tienen correo" }, 400);

  const tz = { timeZone: "Europe/Madrid" } as const;
  const fecha = new Date(m.desde).toLocaleDateString("es-ES", { ...tz, weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const h = (d: string) => new Date(d).toLocaleTimeString("es-ES", { ...tz, hour: "2-digit", minute: "2-digit" });
  const asunto = `Reunión «${m.titulo}»: ${fecha}, ${h(m.desde)}`;
  const texto = (n: string) => `Hola ${n}:\n\nTienes una reunión en el CRM de IZONE.\n\nReunión: ${m.titulo}\nFecha: ${fecha}\nHorario: de ${h(m.desde)} a ${h(m.hasta)} (hora de Madrid)\nContraseña de la reunión: ${m.clave}\n\nMientras dure, entra en ${CRM} con tu correo y tu contraseña de siempre. Después el CRM te pedirá la contraseña de la reunión.${m.notas ? "\n\nNotas: " + m.notas : ""}\n\nNo compartas esta contraseña.\n${yo.nombre} · IZONE events`;
  const html = (n: string) => `<div style="font-family:Arial,sans-serif;font-size:15px;color:#111;max-width:520px"><p style="font-size:22px;font-weight:700;margin:0 0 16px"><span style="color:#B9006B">I</span>-ZONE <span style="font-weight:400;font-size:14px">events</span></p>
<p>Hola ${esc(n)}:</p><p>Tienes una reunión en el CRM de IZONE.</p>
<table style="border-collapse:collapse;margin:12px 0"><tr><td style="padding:4px 12px 4px 0;color:#666">Reunión</td><td><b>${esc(m.titulo)}</b></td></tr><tr><td style="padding:4px 12px 4px 0;color:#666">Fecha</td><td>${esc(fecha)}</td></tr><tr><td style="padding:4px 12px 4px 0;color:#666">Horario</td><td>de ${h(m.desde)} a ${h(m.hasta)} (hora de Madrid)</td></tr><tr><td style="padding:4px 12px 4px 0;color:#666">Contraseña</td><td><b style="font-family:monospace;font-size:18px;letter-spacing:1px;background:#f6e6ef;padding:2px 8px;border-radius:6px">${esc(m.clave)}</b></td></tr></table>
<p>Mientras dure, entra en el CRM con tu correo y tu contraseña de siempre. Después te pedirá la contraseña de la reunión.</p>${m.notas ? `<p style="color:#555"><b>Notas:</b> ${esc(m.notas)}</p>` : ""}
<p><a href="${CRM}" style="display:inline-block;background:#B9006B;color:#fff;text-decoration:none;padding:10px 18px;border-radius:999px">Abrir el CRM</a></p><p style="color:#888;font-size:13px">No compartas esta contraseña. ${esc(yo.nombre)} · IZONE events</p></div>`;

  const resend = Deno.env.get("RESEND_API_KEY"), smtpHost = Deno.env.get("SMTP_HOST");
  const from = Deno.env.get("MAIL_FROM") || (smtpHost ? Deno.env.get("SMTP_USER") : "") || "";
  if (!resend && !smtpHost) return json({ ok: false, sinConfigurar: true });
  const enviados: string[] = [], fallos: string[] = [];
  let smtp: SMTPClient | null = null;
  try {
    if (!resend) smtp = new SMTPClient({ connection: { hostname: smtpHost!, port: Number(Deno.env.get("SMTP_PORT") || 465), tls: true, auth: { username: Deno.env.get("SMTP_USER")!, password: Deno.env.get("SMTP_PASS")! } } });
    for (const p of destinos) {
      try {
        if (resend) {
          const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${resend}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: from || "IZONE CRM <onboarding@resend.dev>", to: [p.email], subject: asunto, text: texto(p.nombre), html: html(p.nombre) }) });
          if (!r.ok) throw new Error((await r.text()).slice(0, 200));
        } else await smtp!.send({ from: from!, to: p.email, subject: asunto, content: texto(p.nombre), html: html(p.nombre) });
        enviados.push(p.email);
      } catch (e) { fallos.push(`${p.email}: ${(e as Error).message}`.slice(0, 240)); }
    }
  } finally { try { await smtp?.close(); } catch { /* */ } }
  await admin.from("reuniones").update({ aviso_enviado: new Date().toISOString(), aviso_detalle: { enviados, fallos, por: yo.nombre } }).eq("id", m.id);
  return json({ ok: enviados.length > 0, enviados, fallos });
});
