# API

[← Documentación](README.md)

La API permite que un cliente envíe operaciones al relay y recupere su estado.
Este documento resume las rutas. La definición autoritativa está en
`service/src/api.rs`. La API `v0.1` puede cambiar.

## Resumen

Un cliente se autentica, envía una orden con una clave de idempotencia, recibe
su aceptación durable y sigue el resultado mediante eventos o consultas.

## Alcance actual

Cada instancia de relay acepta una generación activa de engine. Los clientes
eligen entre instancias mediante perfiles y endpoints.

Una orden de `v0.1` **no** incluye un `hostId` para que una sola central elija
entre varios engines. La estrella N×M de [Arquitectura](ARCHITECTURE.md) es la
forma objetivo, no routing multi-host ya implementado.

## Autenticación

Cada request a `/api/mobile/*` necesita el header `Authorization` con el valor
`Bearer <client-token>`.

Las respuestas protegidas usan una política privada `no-store`. `/healthz` es
público y devuelve sólo disponibilidad acotada.

El engine usa otro token. No reutilices el token de cliente para su conexión.

## Rutas usadas por los clientes

Las rutas están agrupadas para que se puedan consultar cómodamente desde una
pantalla pequeña. Abrí sólo el bloque que necesitás.

<details>
<summary><strong>Disponibilidad y sesiones</strong></summary>

- `GET /healthz` — disponibilidad del relay y del engine.
- `GET /api/mobile/sessions` — resúmenes de sesiones administradas por Fermín.
- `POST /api/mobile/sessions` — crear una sesión.
- `GET /api/mobile/sessions/{id}` — obtener el detalle completo.
- `POST /api/mobile/sessions/{id}/message` — enviar un mensaje durable.
- `POST /api/mobile/sessions/{id}/steer` — orientar el turno activo.
- `POST /api/mobile/sessions/{id}/interrupt` — interrumpir el trabajo actual.

</details>

<details>
<summary><strong>Organización de sesiones</strong></summary>

- `POST /api/mobile/sessions/{id}/archive` — archivar sin borrar historial.
- `DELETE /api/mobile/sessions/{id}/permanent` — borrar permanentemente.
- `PUT /api/mobile/sessions/{id}/pinned` — cambiar el estado fijado compartido.
- `POST /api/mobile/sessions/{id}/rename` — renombrar.
- `POST /api/mobile/sessions/{id}/minimize` — ocultar.
- `POST /api/mobile/sessions/{id}/restore` — restaurar una sesión oculta.

</details>

<details>
<summary><strong>Modelo, modo y funciones</strong></summary>

- `GET /api/mobile/sessions/{id}/models` — modelos disponibles.
- `POST /api/mobile/sessions/{id}/model-settings` — cambiar ajustes del modelo.
- `POST /api/mobile/sessions/{id}/run-mode` — cambiar el modo de ejecución.
- `POST /api/mobile/sessions/{id}/features` — cambiar funciones de Fermín.

</details>

<details>
<summary><strong>Archivos y adjuntos</strong></summary>

- `POST /api/mobile/sessions/{id}/attachments` — subir un adjunto acotado.
- `GET /api/mobile/projects` — listar proyectos permitidos.
- `POST /api/mobile/file-preview` — obtener una vista previa acotada.
- `GET /api/mobile/attachments/content` — descargar contenido acotado.

</details>

<details>
<summary><strong>Historial, recuperación y eventos</strong></summary>

- `GET /api/mobile/commands/{id}` — estado actual de una orden durable.
- `GET /api/mobile/session-history` — buscar sesiones anteriores.
- `POST /api/mobile/session-history/resume` — reanudar una sesión anterior.
- `GET /api/mobile/session-recovery` — encontrar una sesión recuperable.
- `POST /api/mobile/session-recovery/recover` — recuperar la sesión elegida.
- `GET /api/mobile/stream` — recibir eventos SSE en vivo.

</details>

`service/src/api.rs` también define rutas acotadas para subagentes,
transformación de prompts y preferencias.

## Semántica de `accepted`

`accepted` significa que el relay guardó la orden. No significa que Codex la
terminó.

El recorrido habitual es:

1. `accepted`: el relay tomó custodia.
2. `leased`: el engine recibió una lease de la orden.
3. `engineDurable`: el engine la guardó localmente.
4. `sentToChild`: la entregó al proceso de Codex.
5. `completed`: terminó correctamente.

El recorrido también puede terminar en `failed`, `cancelled` o `unknown`.

Al reintentar la misma acción del usuario, enviá la misma clave de
idempotencia. El relay reconoce que se trata de la misma operación. Una clave
nueva representa otra operación.

## Eventos y reconexión

`GET /api/mobile/stream` emite Server-Sent Events ordenados. Cada evento tiene
un identificador de secuencia. Un cliente que vuelve envía su cursor en el
query o mediante `Last-Event-ID`.

Si el historial disponible no alcanza para ese cursor, el cliente debe recargar
el snapshot autoritativo. No debe interpretar la falta de replay como “no cambió
nada”.

Cada cliente mantiene su cursor. Por eso iPhone y Desktop pueden desconectarse
en momentos distintos y volver después a la misma historia.

## Conexión del engine

El engine abre un WebSocket saliente hacia:

```text
GET /v1/engine/connect
```

Se autentica por separado. La descarga de adjuntos usa tokens opacos de vida
corta. El cliente nunca usa esta conexión ni habla directamente con el engine.

## Rutas de compatibilidad

El montaje original de dos hosts también expone la API bajo `/fermin-code`,
`/fermin-code-puky` y `/sync-hub`. Se conservan por compatibilidad. Una
instalación nueva no necesita copiar esos nombres.

---

[← Arquitectura](ARCHITECTURE.md) · [Documentación](README.md) ·
[Siguiente: Modelo de seguridad →](SECURITY_MODEL.md)
