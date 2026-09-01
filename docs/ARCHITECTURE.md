# Arquitectura

[← Documentación](README.md)

## Resumen

Fermín separa el cliente remoto del proceso local de Codex mediante dos
componentes:

- el **relay**, que autentica, persiste, ordena y distribuye; y
- el **engine**, que se ejecuta junto a Codex en la Mac host.

```text
Cliente
   ↓
Relay
   ↓
Engine
   ↓
Codex App Server
```

Los clientes no se conectan directamente al engine. Codex App Server permanece
local en el host.

Fermín transporta órdenes y eventos estructurados. No transmite la pantalla de
la Mac y no funciona como escritorio remoto.

## Topología implementada en `v0.1`

Una instancia de relay admite una generación activa de engine. El despliegue
actual para dos hosts usa dos pares independientes.

```text
Primary
   ↓
Relay
   ↓
Engine
   ↓
Codex
```

```text
Secondary
   ↓
Relay
   ↓
Engine
   ↓
Codex
```

Mobile y Desktop ofrecen perfiles Primary, Secondary y All. El perfil determina
el endpoint que recibe la orden. Las solicitudes actuales no incluyen un
`hostId` para que una sola instancia de relay seleccione entre varios engines.

La versión actual permite:

- varios clientes sobre el mismo par relay–engine;
- selección de dos hosts mediante perfiles de endpoint;
- un cursor de eventos independiente por cliente; y
- reconexión y replay desde ese cursor.

## Topología objetivo

La arquitectura objetivo registra varios hosts en un único relay.

<a href="images/architecture/relay-star-mobile.svg">
  <picture>
    <source media="(max-width: 600px)" srcset="images/architecture/relay-star-mobile.svg">
    <img src="images/architecture/relay-star-platform.svg" alt="N clientes conectados con M hosts mediante un relay durable central">
  </picture>
</a>

<sub>La imagen se puede abrir en resolución completa. Representa la arquitectura
objetivo, no el routing disponible en `v0.1`.</sub>

En esa topología:

1. cada host registra su identidad en el relay;
2. cada orden identifica un host de destino;
3. el relay autoriza y entrega la orden al engine correspondiente; y
4. cada host mantiene su propia lease y generación de fencing.

El routing multi-host dentro de una instancia todavía no está implementado. El
diagrama define una dirección de diseño y no una fecha de entrega.

## Componentes

### Cliente

Mobile y Desktop:

- usan REST para consultas y órdenes durables;
- reciben eventos mediante Server-Sent Events (SSE);
- guardan un cursor por fuente;
- usan polling acotado como recuperación si SSE deja de responder; y
- almacenan tokens en Keychain.

Los clientes no inician Codex, no ejecutan el engine y no exponen un servidor
HTTP local.

### Relay

El relay:

- autentica las solicitudes HTTP de clientes;
- persiste una orden antes de responder `accepted`;
- reconoce reintentos mediante claves de idempotencia;
- conserva comandos, snapshots, eventos, alias y cursores en SQLite;
- entrega eventos ordenados mediante SSE;
- reanuda desde un cursor o `Last-Event-ID`;
- mantiene el heartbeat y la lease del engine;
- rechaza escrituras de generaciones anteriores mediante fencing; y
- conserva trabajo pendiente si el engine se desconecta mientras el relay
  continúa disponible.

El relay no ejecuta herramientas y no accede directamente al workspace.

### Engine

Cada Mac host ejecuta un engine. El engine:

- inicia Codex App Server como proceso hijo;
- se comunica con App Server mediante JSONL por entrada y salida estándar;
- valida la versión, el esquema, los modelos y las capacidades;
- rechaza rutas fuera de `workspaceRoots`;
- traduce operaciones de Fermín a threads y turns de Codex;
- conserva sesiones, comandos, eventos, cursores, epochs y leases en SQLite
  WAL;
- expone sólo sesiones administradas por Fermín;
- procesa cada sesión en un carril separado; y
- mantiene App Server fuera de la red.

Si App Server termina, el engine deja de informar estado listo. El reinicio
continuo depende del supervisor configurado por quien opera la instalación.
Una ejecución manual sin supervisor no se reinicia indefinidamente.

### Codex App Server

App Server administra threads, turns, herramientas, sandbox, aprobaciones y
ejecución. El engine adapta su protocolo; el relay y los clientes no duplican
esas funciones.

## Ciclo de una orden

Este ejemplo usa Mobile y el perfil Primary:

1. Mobile genera una clave de idempotencia.
2. Mobile envía la orden al relay Primary.
3. El relay autentica y persiste la orden en SQLite.
4. El relay responde `accepted`.
5. El engine conectado recibe la orden y la guarda localmente.
6. El carril de la sesión entrega la operación a Codex App Server.
7. Los eventos regresan al relay y reciben una secuencia.
8. Mobile y Desktop consumen esos eventos desde sus propios cursores.

`accepted` significa que el relay guardó la orden. No significa que el engine
la haya recibido ni que Codex haya terminado.

## Varios clientes sobre un host

Mobile y Desktop pueden observar y modificar las mismas sesiones. Cada cliente
mantiene su cursor, pero ambos reconstruyen el estado desde el registro del
relay.

Cuando dos clientes envían órdenes a una misma sesión, el relay persiste cada
orden y asigna una secuencia. El engine procesa el trabajo de esa sesión de
forma secuencial.

Este orden no implica ejecución exactamente una vez. Si Codex recibe una orden
y el engine falla antes de guardar el resultado, el estado puede quedar como
`unknown`. El engine inspecciona la sesión antes de decidir si corresponde
repetir la operación.

## Un cliente sobre varios hosts

En `v0.1`, el cliente selecciona Primary o Secondary y envía la orden a una
instancia distinta. No existe routing multi-host dentro de una sola instancia.

La topología objetivo mueve esa selección al relay. Para implementarla se
requieren identidad, autorización, almacenamiento, leases y fencing separados
por host. Agregar sólo un campo `hostId` no es suficiente.

## Mecanismos de confiabilidad

### Persistencia

El relay y el engine guardan estado antes de avanzar entre etapas. La recepción
no depende únicamente de una conexión activa.

### Idempotencia

Un reintento con la misma clave representa la misma operación. Una clave nueva
representa otra operación.

### Cola y entrega posterior

Si el relay permanece disponible, puede conservar trabajo hasta que el engine
se reconecte. Esta capacidad no enciende una Mac apagada.

### Replay

Cada cliente reanuda desde su último cursor. Si el rango solicitado ya no está
disponible, el cliente debe cargar un snapshot autoritativo.

### Lease y fencing

La lease indica si una conexión de engine sigue vigente. Cuando se registra una
generación nueva, el fencing impide que una conexión anterior continúe
escribiendo.

Los mensajes entre relay y engine incluyen versión de protocolo, identidad del
engine, epoch de conexión, secuencia, ACK, cursor de reanudación y generación
de fencing.

## Comportamiento ante fallas

### Cliente desconectado

Una orden ya aceptada permanece en el relay. Al volver, el cliente solicita los
eventos posteriores a su cursor.

### Engine desconectado

El relay puede mantener órdenes pendientes mientras siga disponible. Cuando el
engine se reconecta, recupera el trabajo correspondiente.

### Relay y engine en la misma Mac

Esta es la topología local mínima. Si la Mac se apaga, el relay deja de aceptar
órdenes y el engine deja de ejecutar.

### Relay y engine en máquinas separadas

```text
Cliente
   ↓
Relay disponible
   ↓
Engine intermitente
```

El relay puede aceptar y conservar órdenes durante una desconexión del host. No
puede ejecutar sin el engine ni activar una Mac apagada.

## Límites de publicación

El repositorio incluye relay, engine, REST, SSE, WebSocket, SQLite, replay,
idempotencia, leases, fencing y límites por `workspaceRoots`.

No incluye cuentas, dominios, rutas de Cloudflare, servicios personales,
tokens, rutas privadas del filesystem ni una sesión autenticada de Codex.

Los alias `/fermin-code`, `/fermin-code-puky` y `/sync-hub` se conservan
por compatibilidad. Una instalación nueva puede usar la API sin prefijo y
elegir sus propias rutas públicas.

## Límites de responsabilidad

- Codex razona y ejecuta.
- El engine controla la integración local de una Mac.
- El relay persiste y distribuye órdenes y eventos.
- Los clientes envían operaciones y presentan el estado.

---

[← Documentación](README.md) · [Siguiente: Autoalojamiento →](SELF_HOSTING.md)
