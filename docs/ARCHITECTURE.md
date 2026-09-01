# Arquitectura

[← Documentación](README.md)

## Resumen

Fermín pone dos piezas entre el cliente y Codex:

- el **relay**, que recibe las órdenes, las guarda y mantiene su historia; y
- el **engine**, el programa que corre junto a Codex en la Mac host.

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

Fermín mueve órdenes y eventos, no píxeles. No transmite la pantalla de la Mac
ni funciona como escritorio remoto.

## Topología implementada en `v0.1`

En `v0.1`, cada relay trabaja con una generación activa de engine. Para conectar
dos hosts se usan dos pares independientes.

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

Mobile y Desktop ofrecen los perfiles Primary, Secondary y All. Elegir un
perfil es elegir el endpoint que recibe la orden. Las solicitudes actuales no
incluyen un `hostId`, por lo que un solo relay todavía no puede elegir entre
varios engines.

La versión actual permite:

- varios clientes sobre el mismo par relay–engine;
- selección de dos hosts mediante perfiles de endpoint;
- un cursor de eventos independiente por cliente; y
- reconexión y replay desde ese cursor.

## Topología objetivo

El diseño al que apunta Fermín registra varios hosts en un único relay.

<a href="images/architecture/relay-star-mobile.svg">
  <picture>
    <source media="(max-width: 600px)" srcset="images/architecture/relay-star-mobile.svg">
    <img src="images/architecture/relay-star-platform.svg" alt="N clientes conectados con M hosts mediante un relay durable central">
  </picture>
</a>

<sub>La imagen se puede abrir en resolución completa. Representa la arquitectura
objetivo, no el routing disponible en `v0.1`.</sub>

En esa versión del diseño:

1. cada host registra su identidad en el relay;
2. cada orden identifica un host de destino;
3. el relay autoriza y entrega la orden al engine correspondiente; y
4. cada host mantiene su propia lease y generación de fencing.

La selección de varios hosts dentro de una instancia todavía no está
implementada. El diagrama muestra la dirección del diseño, no una fecha de
entrega.

## Componentes

### Cliente

Mobile y Desktop son clientes del relay. Ambos:

- usan REST para consultas y órdenes durables;
- reciben eventos mediante Server-Sent Events (SSE);
- guardan un cursor por fuente para saber hasta dónde leyeron;
- consultan el estado de forma acotada si SSE deja de responder; y
- almacenan tokens en Keychain.

Los clientes no inician Codex, no ejecutan el engine y no exponen un servidor
HTTP local.

### Relay

El relay es la central que recibe y conserva el trabajo. En concreto:

- autentica las solicitudes HTTP de clientes;
- guarda una orden antes de responder `accepted`;
- reconoce reintentos mediante claves de idempotencia;
- conserva comandos, snapshots, eventos, alias y cursores en SQLite;
- entrega eventos ordenados mediante SSE;
- retoma la historia desde un cursor o `Last-Event-ID`;
- mantiene el heartbeat y la lease del engine;
- rechaza escrituras de generaciones anteriores mediante fencing; y
- conserva trabajo pendiente si el engine se desconecta mientras el relay
  continúa disponible.

El relay no hace el trabajo de Codex ni entra directamente al workspace.

### Engine

Cada Mac host ejecuta un engine, el programa local que conecta el relay con
Codex. El engine:

- inicia Codex App Server como un proceso local;
- habla con App Server mediante JSONL por entrada y salida estándar;
- comprueba la versión, el esquema, los modelos y las capacidades;
- rechaza rutas fuera de `workspaceRoots`;
- convierte operaciones de Fermín en threads y turns de Codex;
- conserva sesiones, comandos, eventos, cursores, epochs y leases en SQLite
  WAL;
- expone sólo sesiones administradas por Fermín;
- procesa cada sesión en un carril separado; y
- mantiene App Server fuera de la red.

Si App Server termina, el engine deja de mostrarse como listo. Para levantarlo
otra vez de forma automática hace falta un supervisor configurado por quien
opera la instalación. Si ejecutás todo a mano, ese reinicio no ocurre solo.

### Codex App Server

App Server sigue siendo el runtime de Codex: administra threads, turns,
herramientas, sandbox, aprobaciones y ejecución. El engine adapta su protocolo;
el relay y los clientes no vuelven a implementar esas funciones.

## Ciclo de una orden

Este es el recorrido de una orden enviada desde Mobile al perfil Primary:

1. Mobile genera una clave de idempotencia.
2. Mobile envía la orden al relay Primary.
3. El relay verifica el token y guarda la orden en SQLite.
4. El relay responde `accepted`.
5. El engine conectado recibe la orden y la guarda localmente.
6. El carril de la sesión entrega la operación a Codex App Server.
7. Los eventos regresan al relay y reciben una secuencia.
8. Mobile y Desktop consumen esos eventos desde sus propios cursores.

`accepted` significa “el relay ya la tiene”. No significa que el engine la haya
recibido ni que Codex haya terminado.

## Varios clientes sobre un host

Mobile y Desktop pueden abrir y modificar las mismas sesiones. Cada uno guarda
su propio cursor, pero los dos reconstruyen el estado desde la misma historia
del relay.

Si los dos clientes mandan órdenes a una misma sesión, el relay guarda cada una
y les asigna una secuencia. El engine procesa el trabajo de esa sesión en
orden.

Ese orden no significa que exista una garantía de ejecución exactamente una
vez. Si Codex recibe una orden y el engine falla antes de guardar el resultado,
el estado puede quedar como `unknown`. Antes de repetirla, el engine revisa qué
ocurrió en la sesión.

## Un cliente sobre varios hosts

En `v0.1`, el cliente elige Primary o Secondary y manda la orden a una instancia
distinta. Un solo relay todavía no puede elegir entre varios hosts.

El diseño futuro mueve esa decisión al relay. Para hacerlo bien se necesitan
identidad, autorización, almacenamiento, leases y fencing separados por host.
Agregar sólo un campo `hostId` no alcanza.

## Mecanismos de confiabilidad

### Persistencia

El relay y el engine guardan el estado antes de pasar a la etapa siguiente. La
orden no depende solamente de que la conexión siga abierta en ese momento.

### Idempotencia

Si el cliente reintenta con la misma clave, el relay reconoce la misma
operación. Una clave nueva representa una orden nueva.

### Cola y entrega posterior

Mientras el relay siga disponible, puede guardar trabajo hasta que el engine
vuelva. Eso no enciende una Mac apagada.

### Replay

Cada cliente recuerda su último cursor y pide lo que ocurrió después. Si esa
parte de la historia ya no está disponible, carga un snapshot completo.

### Lease y fencing

La lease indica si una conexión del engine sigue vigente. Si aparece una
generación nueva, el fencing evita que la conexión anterior siga escribiendo.

Los mensajes entre relay y engine incluyen versión de protocolo, identidad del
engine, epoch de conexión, secuencia, ACK, cursor de reanudación y generación
de fencing.

## Comportamiento ante fallas

### Cliente desconectado

Una orden ya aceptada sigue guardada en el relay. Al volver, el cliente pide los
eventos que ocurrieron después de su cursor.

### Engine desconectado

El relay puede guardar órdenes pendientes mientras siga disponible. Cuando el
engine vuelve, recupera ese trabajo.

### Relay y engine en la misma Mac

Esta es la instalación local más simple. Si la Mac se apaga, el relay deja de
recibir órdenes y el engine deja de ejecutar.

### Relay y engine en máquinas separadas

```text
Cliente
   ↓
Relay disponible
   ↓
Engine intermitente
```

El relay puede recibir y guardar órdenes mientras el host está desconectado. No
puede ejecutarlas sin el engine ni encender una Mac apagada.

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
- El engine conecta una Mac con Codex.
- El relay guarda y distribuye órdenes y eventos.
- Los clientes envían operaciones y presentan el estado.

---

[← Documentación](README.md) · [Siguiente: Autoalojamiento →](SELF_HOSTING.md)
