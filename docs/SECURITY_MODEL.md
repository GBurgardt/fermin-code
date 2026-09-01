# Modelo de seguridad

[← Documentación](README.md)

## Resumen

Fermín puede llevar una orden hasta una Mac que tiene acceso a archivos y
procesos. Por eso la seguridad no es secundaria: el relay recibe las órdenes y
el engine decide qué puede ocurrir dentro del host.

## Nivel de acceso

Desde Fermín se le puede pedir a Codex que lea archivos, cambie un workspace o
ejecute comandos en una Mac autorizada. Quien tiene un token de cliente puede
llegar a operaciones con ese nivel de acceso.

Si no le darías ese acceso a un dispositivo o a quien guarda un token, no lo
conectes al relay.

## Controles implementados

La versión pública ya aplica estos límites:

- Los listeners del relay y del engine deben ligarse a loopback.
- El tráfico remoto entra mediante un edge TLS separado o un túnel saliente.
- Clientes y engines usan bearer tokens diferentes.
- El servicio lee secretos desde archivos privados con ruta absoluta y rechaza
  permisos Unix demasiado amplios.
- Los clientes Apple guardan tokens en Keychain.
- `workspaceRoots` limita los directorios que acepta el engine.
- Requests, líneas JSONL, frames WebSocket, páginas de replay, vistas previas y
  adjuntos tienen límites de tamaño.
- Las claves de idempotencia evitan duplicar órdenes durables al reintentar.
- Leases y fencing impiden que una conexión vieja conserve autoridad.
- Las respuestas protegidas deshabilitan cachés compartidos.
- Codex App Server permanece local en la Mac controlada.

## Qué debe proteger quien lo opera

El repositorio no puede decidir cómo protegés tu red y tu Mac. Quien instala
Fermín debe:

1. Usá HTTPS y WSS en cada conexión que salga de loopback.
2. Generá tokens aleatorios y separados de al menos 32 caracteres.
3. Mantené los archivos de token en modo `0600` y fuera de logs, TOML,
   historial del shell y Git.
4. Dale al engine la lista mínima útil de `workspaceRoots`.
5. Elegí sandbox y aprobaciones de Codex acordes al riesgo de la Mac.
6. Actualizá y protegé macOS, Codex, el túnel y el reverse proxy.
7. Definí retención para las bases del relay y los adjuntos.

Nunca pongas un bearer token en una URL. Nunca expongas el listener del engine
ni Codex App Server directamente a Internet.

## Seguridad de una central con varios hosts

La estrella N×M describe el diseño futuro, pero `v0.1` todavía no comparte un
relay entre varios hosts. Antes de que una central pueda hacerlo de forma
segura necesita, como mínimo:

- identidad estable de cuenta, cliente y host;
- autorización por host, workspace, sesión y operación;
- aislamiento entre usuarios;
- una lease y generación de fencing independientes por host;
- revocación y rotación de dispositivos;
- auditoría del origen y destino de cada orden; y
- límites y cuotas por cuenta.

Agregar `hostId` a una orden no alcanza. Hasta que existan esos controles, no
uses el relay actual como servicio multi-tenant ni conectes engines de personas
distintas a una misma instancia.

## Funciones que esta versión no incluye

Esta versión todavía no incluye:

- cuentas u OAuth/OIDC;
- pairing de dispositivos;
- credenciales breves y una interfaz de rotación;
- aislamiento multi-tenant y autorización por objeto;
- consola alojada de auditoría y revocación;
- cifrado de extremo a extremo del contenido;
- distribución binaria firmada o notarizada;
- actualizaciones automáticas; ni
- un perfil de autoridad seguro por defecto para usuarios no técnicos.

## Una orden guardada puede ejecutarse más tarde

Si el host está fuera de línea, una orden guardada puede ejecutarse cuando
vuelva. Esta versión no ofrece una regla general para vencer o volver a
confirmar órdenes demoradas. Encolá sólo trabajo que siga siendo seguro más
tarde.

Una Mac dormida, apagada o aislada de la red sigue indisponible. Las funciones
de wake de red no son una garantía.

## Reportar una vulnerabilidad

No publiques detalles de exploits ni secretos sospechados en un issue. Seguí
[SECURITY.md](../SECURITY.md) y usá el reporte privado de vulnerabilidades de
GitHub.

---

[← API](API.md) · [Documentación](README.md) ·
[Volver a Autoalojamiento →](SELF_HOSTING.md)
