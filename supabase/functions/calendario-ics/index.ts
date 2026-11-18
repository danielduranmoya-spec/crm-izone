// Calendario de bodas CERRADAS en formato iCalendar, para suscribirse desde Google Calendar.
// URL: /functions/v1/calendario-ics?t=TOKEN  (el token lo genera un administrador en Ajustes y se puede cambiar).
import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CERRADAS = ["Cerrada", "Confirmada", "Celebrada"];

function iguales(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const esc = (s: unknown) => String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
// Plegado de líneas a 75 octetos (RFC 5545)
function plegar(l: string) {
  const enc = new TextEncoder(); if (enc.encode(l).length <= 75) return l;
  const out: string[] = []; let cur = "";
  for (const ch of l) { if (enc.encode(cur + ch).length > (out.length ? 74 : 75)) { out.push(cur); cur = ""; } cur += ch; }
  out.push(cur); return out.join("\r\n ");
}
const ymd = (s: string) => s.replace(/-/g, "");
function diaSiguiente(s: string) { const d = new Date(s + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); }
const hm = (s: string) => /^\d{2}:\d{2}/.test(s || "") ? s.slice(0, 5).replace(":", "") + "00" : "";

Deno.serve(async (req) => {
  const t = new URL(req.url).searchParams.get("t") || "";
  const { data: sec } = await admin.from("secretos").select("valor").eq("id", "ics_token").maybeSingle();
  if (!sec || !t || !iguales(t, sec.valor)) return new Response("No autorizado", { status: 401 });
  const { data: bodas, error } = await admin.from("bodas").select("id,data");
  if (error) return new Response("Error", { status: 500 });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z";
  const ev: string[] = [];
  for (const { id, data: b } of bodas || []) {
    if (!b || !b.fecha || !CERRADAS.includes(b.estado)) continue;
    const novios = [b.novios?.n1?.nombre, b.novios?.n2?.nombre].map((s: string) => (s || "").trim()).filter(Boolean).join(" & ") || "Boda";
    const L = b.lugar || {};
    const lugar = [L.nombre, L.direccion, [L.cp, L.localidad].filter(Boolean).join(" "), L.provincia].filter(Boolean).join(", ");
    const equipo = [...(b.djs || []).map((d: any) => d.nombre && "DJ: " + d.nombre), ...(b.auxiliares || []).map((a: any) => a.nombre && "Auxiliar: " + a.nombre)].filter(Boolean);
    const desc = [`Estado: ${b.estado}`, b.invitados ? `Invitados: ${b.invitados}` : "", b.horaInicio ? `Horario: ${b.horaInicio}${b.horaFin ? "–" + b.horaFin : ""}` : "", ...equipo, L.contacto ? `Contacto del lugar: ${L.contacto}` : "", b.numero ? `Presupuesto ${b.numero}` : ""].filter(Boolean).join("\n");
    const ini = hm(b.horaInicio), fin = hm(b.horaFin);
    let cuando: string[];
    if (ini) {
      const finDia = fin && fin <= ini ? diaSiguiente(b.fecha) : b.fecha;
      cuando = [`DTSTART;TZID=Europe/Madrid:${ymd(b.fecha)}T${ini}`, `DTEND;TZID=Europe/Madrid:${ymd(fin ? finDia : b.fecha)}T${fin || ini}`];
    } else cuando = [`DTSTART;VALUE=DATE:${ymd(b.fecha)}`, `DTEND;VALUE=DATE:${ymd(diaSiguiente(b.fecha))}`];
    ev.push(["BEGIN:VEVENT", `UID:boda-${id}@crm-izone`, `DTSTAMP:${stamp}`, ...cuando, `SUMMARY:${esc("Boda " + novios)}`, lugar ? `LOCATION:${esc(lugar)}` : "", `DESCRIPTION:${esc(desc)}`, "STATUS:CONFIRMED", "TRANSP:OPAQUE", "END:VEVENT"].filter(Boolean).map(plegar).join("\r\n"));
  }
  const tz = ["BEGIN:VTIMEZONE", "TZID:Europe/Madrid", "BEGIN:DAYLIGHT", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "TZNAME:CEST", "DTSTART:19700329T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU", "END:DAYLIGHT", "BEGIN:STANDARD", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "TZNAME:CET", "DTSTART:19701025T030000", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU", "END:STANDARD", "END:VTIMEZONE"];
  const ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//IZONE EVENTS//CRM Bodas//ES", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Bodas IZONE (cerradas)", "X-WR-TIMEZONE:Europe/Madrid", "REFRESH-INTERVAL;VALUE=DURATION:PT1H", "X-PUBLISHED-TTL:PT1H", ...tz, ...ev, "END:VCALENDAR"].join("\r\n");
  return new Response(ics, { headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-cache", "Content-Disposition": "inline; filename=bodas-izone.ics" } });
});
