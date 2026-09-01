# API: el contrato de la central

La API es la forma concreta en que un cliente entrega una intención al relay y
recupera lo ocurrido. Este documento resume las rutas; la definición real del
protocolo está en `service/src/api.rs`. La API `v0.1` todavía puede cambiar.

## Alcance actual

Cada instancia de relay acepta una generación activa de engine. Los clientes
eligen entre instancias mediante sus perfiles y endpoints. Una orden de `v0.1`
**no** incluye un `hostId` para que una sola central la derive hacia varios
engines.

La estrella N×M descrita en [Arquitectura](ARCHITECTURE.md) es la arquitectura
objetivo. No asumas que el proceso `v0.1` ya implementa routing multi-host.

## Autenticación

Cada request a `/api/mobile/*` necesita el token de cliente:

```http
Authorization: Bearer <client-token>
```

Las respuestas protegidas usan una política privada `no-store`. `/healthz`
es público y devuelve únicamente datos acotados de disponibilidad.

El engine usa otro token. No reutilices el token de cliente para su conexión.

## Rutas usadas por Desktop y Mobile

| Request | Resultado |
| --- | --- |
| `GET /healthz` | Disponibilidad del relay y del engine |
| `GET /api/mobile/sessions` | Resúmenes de sesiones administradas por Fermín |
| `POST /api/mobile/sessions` | Crear una sesión |
| `GET /api/mobile/sessions/{id}` | Detalle completo de una sesión |
| `POST /api/mobile/sessions/{id}/message` | Mensaje durable del usuario |
| `POST /api/mobile/sessions/{id}/steer` | Nueva instrucción para el turno activo |
| `POST /api/mobile/sessions/{id}/interrupt` | Interrumpir el trabajo actual |
| `POST /api/mobile/sessions/{id}/archive` | Archivar sin borrar el historial |
| `DELETE /api/mobile/sessions/{id}/permanent` | Borrado permanente |
| `PUT /api/mobile/sessions/{id}/pinned` | Cambiar el estado fijado compartido |
| `POST /api/mobile/sessions/{id}/rename` | Renombrar una sesión |
| `POST /api/mobile/sessions/{id}/minimize` | Ocultar una sesión |
| `POST /api/mobile/sessions/{id}/restore` | Restaurar una sesión oculta |
| `GET /api/mobile/sessions/{id}/models` | Modelos disponibles para la sesión |
| `POST /api/mobile/sessions/{id}/model-settings` | Cambiar ajustes del modelo |
| `POST /api/mobile/sessions/{id}/run-mode` | Cambiar el modo de ejecución |
| `POST /api/mobile/sessions/{id}/features` | Cambiar funciones de Fermín |
| `POST /api/mobile/sessions/{id}/attachments` | Subir un adjunto con límite de tamaño |
| `GET /api/mobile/commands/{id}` | Estado actual de una orden durable |
| `GET /api/mobile/projects` | Proyectos permitidos |
| `POST /api/mobile/file-preview` | Vista previa acotada de un archivo |
| `GET /api/mobile/attachments/content` | Contenido acotado de un adjunto |
| `GET /api/mobile/session-history` | Buscar sesiones anteriores |
| `POST /api/mobile/session-history/resume` | Reanudar una sesión anterior |
| `GET /api/mobile/session-recovery` | Encontrar una sesión recuperable |
| `POST /api/mobile/session-recovery/recover` | Recuperar la sesión elegida |
| `GET /api/mobile/stream` | Eventos SSE en vivo |

`service/src/api.rs` también define rutas acotadas para subagentes,
transformación de prompts y preferencias.

## Aceptar es tomar custodia, no terminar

`accepted` significa que el relay guardó la orden y tomó custodia de ella. No
significa que Codex la terminó.

Estados habituales:

```text
accepted → leased → engineDurable → sentToChild → completed
                                               └→ failed/cancelled/unknown
```

Al reintentar la misma acción del usuario, enviá la misma clave de idempotencia.
Así el relay reconoce la misma intención. Una clave nueva representa una acción
nueva.

## Eventos y reconexión

`GET /api/mobile/stream` emite Server-Sent Events ordenados. Cada evento tiene
un identificador de secuencia del relay. Un cliente que vuelve envía un cursor
en el query o `Last-Event-ID`.

Si el historial disponible no alcanza para ese cursor, el cliente debe recargar
el snapshot autoritativo. No debe interpretar la falta de replay como “no
cambió nada”.

Cada cliente mantiene su cursor. Por eso iPhone y Desktop pueden desconectarse
en momentos diferentes y volver después a la misma historia.

## Conexión del engine

El engine abre un WebSocket saliente hacia:

```text
GET /v1/engine/connect
```

Se autentica por separado. La descarga de adjuntos usa tokens opacos de vida
corta. El cliente nunca usa esta conexión ni habla directo con el engine.

## Rutas de compatibilidad

El montaje original de dos hosts también expone la API bajo
`/fermin-code`, `/fermin-code-puky` y `/sync-hub`. Se conservan por
compatibilidad. Una instalación nueva no necesita copiar esos nombres.
