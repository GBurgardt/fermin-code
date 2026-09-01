# API

[← Documentación](README.md)

La API es la forma en que Mobile, Desktop u otro cliente hablan con el relay.
Este documento reúne las rutas principales. La definición exacta está en
`service/src/api.rs` y todavía puede cambiar durante `v0.1`.

## Resumen

El cliente se autentica, manda una orden con una clave única y recibe
`accepted` cuando el relay termina de guardarla. Desde ahí puede seguir lo que
ocurre mediante eventos o consultas.

## Alcance actual

Cada relay trabaja con una generación activa de engine. Para elegir otra Mac,
el cliente usa otro perfil y otro endpoint.

Una orden de `v0.1` **no** incluye un `hostId`, así que una sola central todavía
no puede elegir entre varios engines. La estrella N×M de
[Arquitectura](ARCHITECTURE.md) es el diseño futuro, no una capacidad ya
implementada.

## Autenticación

Cada solicitud a `/api/mobile/*` necesita el header `Authorization` con el valor
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

`accepted` significa que el relay ya guardó la orden. No significa que Codex
haya terminado.

El recorrido habitual es:

1. `accepted`: el relay ya tiene la orden.
2. `leased`: el engine reservó esa orden para procesarla.
3. `engineDurable`: el engine también la guardó en la Mac.
4. `sentToChild`: la orden llegó al proceso de Codex.
5. `completed`: el trabajo terminó correctamente.

El recorrido también puede terminar en `failed`, `cancelled` o `unknown`.

Si reintentás la misma acción, enviá la misma clave de idempotencia. Así el
relay reconoce la orden y no crea otra. Una clave nueva representa una operación
nueva.

## Eventos y reconexión

`GET /api/mobile/stream` emite Server-Sent Events ordenados. Cada evento tiene
un número de secuencia. Cuando un cliente vuelve, envía el último número que vio
en el query o mediante `Last-Event-ID`.

Si esa parte de la historia ya no está disponible, el cliente recarga un
snapshot completo. No debe interpretar la falta de replay como “no cambió
nada”.

Cada cliente guarda su propio cursor. Por eso el iPhone y Desktop pueden
desconectarse en momentos distintos y, al volver, reconstruir la misma historia.

## Conexión del engine

El engine inicia un WebSocket hacia el relay:

```text
GET /v1/engine/connect
```

Usa un token distinto del cliente. La descarga de adjuntos usa tokens opacos de
vida corta. Mobile y Desktop nunca usan esta conexión ni hablan directamente
con el engine.

## Rutas de compatibilidad

El montaje original de dos hosts también expone la API bajo `/fermin-code`,
`/fermin-code-puky` y `/sync-hub`. Se conservan por compatibilidad. Una
instalación nueva no necesita copiar esos nombres.

---

[← Arquitectura](ARCHITECTURE.md) · [Documentación](README.md) ·
[Siguiente: Modelo de seguridad →](SECURITY_MODEL.md)
