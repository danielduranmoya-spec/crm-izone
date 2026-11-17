# CRM IZONE

CRM de bodas de IZONE. Funciona en cualquier navegador (portátil, tablet o móvil) sin instalar nada.

- **Web:** https://danielduranmoya-spec.github.io/crm-izone/
- **Backend:** Supabase (proyecto `ujqbqiggdcqdsxtqxaox`): usuarios, roles, permisos por sección, historial de accesos y accesos temporales, todo protegido con Row Level Security en el servidor.

## Primer uso
La primera persona que abre la web crea la cuenta de administrador. A partir de ahí, solo los administradores (máximo 3) dan de alta empleados y accesos temporales desde **Equipo**.

## Estructura
- `index.html`: la aplicación completa (lector de PDF con pdf.js y OCR con tesseract.js, sin dependencias de IA).
- `supabase/schema.sql`: tablas, funciones y políticas de seguridad.
- `supabase/functions/admin-usuarios`: función que crea usuarios, cambia contraseñas y borra cuentas (solo admins).

La clave que aparece en `index.html` es la clave pública (anon) de Supabase: está pensada para ir en el navegador y no da acceso a nada sin iniciar sesión.
