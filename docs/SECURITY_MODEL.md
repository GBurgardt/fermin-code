# Modelo de seguridad

[← Documentación](README.md)

Un token de cliente permite dirigir Codex en tu Mac. Tratá ese acceso como
acceso a una máquina con archivos, herramientas y, posiblemente, credenciales.
Esta versión experimental está pensada para una persona que opera su entorno.

## Permisos reales

El adaptador solicita `approvalPolicy=never`. No esperes que Fermín te muestre
una aprobación antes de cada acción. Las solicitudes de aprobación que llegan
al adaptador se rechazan; las preguntas estructuradas reciben una respuesta
vacía. Esa respuesta no equivale a consentimiento humano.

El proceso principal no fija un sandbox propio: el acceso efectivo depende de
Codex y de la configuración del host. La política de aprobación y el sandbox
son controles distintos; `never` no significa por sí solo acceso total.
[Documentación oficial de Codex](https://learn.chatgpt.com/docs/agent-approvals-security#sandbox-and-approvals).

`workspaceRoots` limita rutas aceptadas por el adaptador y las consultas de
archivos. No encierra todos los comandos ni las herramientas dentro de esas
carpetas. No lo uses como sustituto de un sandbox, una cuenta limitada o una
máquina dedicada.

El mejorador y otras llamadas auxiliares tienen su propia configuración
restrictiva. Eso no reduce la autoridad de las sesiones principales.

## Controles implementados

- Listeners de relay y engine ligados a loopback.
- Tokens separados para clientes, conexión engine–relay y API local del engine.
- Secretos en archivos privados: se rechazan rutas relativas, archivos no
  regulares y permisos Unix demasiado amplios.
- Tokens de clientes Apple en Keychain.
- Límites de tamaño para requests, JSONL, WebSocket, replay, previews y adjuntos.
- Idempotencia de órdenes, leases y fencing para conexiones antiguas.
- Respuestas protegidas con caché privada deshabilitada.
- App Server local por stdio, sin publicarlo en la red.

Estos controles no son una auditoría independiente ni una garantía de
inviolabilidad.

## Lo que tiene que resolver quien lo instala

1. Usar un entorno cuya autoridad sea adecuada al trabajo delegado.
2. Revisar el sandbox efectivo de Codex; no habilitar acceso total a ciegas.
3. Generar tokens distintos, aleatorios y de al menos 32 caracteres.
4. Mantenerlos fuera del workspace, Git, logs, URLs y argumentos de comandos.
5. Publicar sólo el relay mediante acceso controlado con HTTPS/WSS.
6. Proteger y actualizar el host, Codex, proxy y túnel.
7. Definir respaldos y retención de bases, adjuntos y conversaciones.

Una VPN sola no hace alcanzable un listener ligado a loopback. El acceso
remoto requiere un proxy o túnel configurado por el operador. No expongas el
engine ni App Server directamente.

## Límites que importan

No hay cuentas, pairing, autorización por usuario u objeto, aislamiento
multi-tenant ni una interfaz de revocación de dispositivos. No compartas una
instancia entre personas con distintos niveles de confianza.

No hay cifrado de extremo a extremo del contenido. El relay puede leer las
órdenes y los eventos; protegé también sus discos y respaldos.

No se distribuyen binarios notarizados, actualizaciones automáticas ni un
supervisor instalado. El repositorio no establece una instalación segura de
un paso para usuarios no técnicos.

Las credenciales de proveedores que usan funciones opcionales de Mobile no
deben distribuirse dentro de una app pública.

## Órdenes demoradas e incertidumbre

Una orden guardada mientras el engine está desconectado puede ejecutarse al
volver. No hay una política general de vencimiento o reconfirmación de esos
pedidos.

Si queda `unknown`, revisá la sesión y los efectos externos antes de
reenviar. Una clave nueva puede repetir una acción que sí llegó a ejecutarse.
Ni `accepted` ni `completed` certifican el resultado del trabajo.

[Reportar una vulnerabilidad en privado](../SECURITY.md) ·
[Autoalojamiento](SELF_HOSTING.md)
