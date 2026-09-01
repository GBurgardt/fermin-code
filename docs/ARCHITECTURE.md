# Arquitectura: una central y varios hosts

## La idea

La arquitectura cabe en una línea:

```text
Mis clientes → Relay durable → Mis hosts → Codex
```

El cliente expresa una intención. El relay toma custodia de ella. El engine de
la Mac indicada la entrega a Codex. Después, la historia vuelve al relay para
que cualquier cliente pueda retomar desde el estado correcto.

- **Codex** razona y ejecuta.
- **El engine** vive junto a Codex y controla la frontera local.
- **El relay durable** recibe, guarda, ordena y deriva.
- **Mobile y Desktop** muestran dos formas de usar el mismo contrato.

No es escritorio remoto: circulan órdenes y eventos estructurados, no píxeles.

## La forma que guía el proyecto: una estrella

![N clientes conectados con M engines mediante un relay central](images/architecture/relay-star-platform.png)

```text
 Cliente 1 ───┐                       ┌─── Engine 1 ─── Codex
 Cliente 2 ───┼─── Relay durable ─────┼─── Engine 2 ─── Codex
 Cliente N ───┘                       └─── Engine M ─── Codex
```

Las conexiones directas cliente→engine no forman parte del modelo. El cliente
habla con la central y expresa el destino. Cada engine conoce únicamente al
relay y abre hacia él una conexión saliente autenticada.

Esta separación permite conectar N clientes con M hosts sin construir una red
de conexiones particulares. El relay concentra el registro durable; los
engines conservan las llaves de sus Macs; Codex conserva el razonamiento y las
herramientas.

## Qué existe hoy

La versión pública actual todavía no es un único proceso multi-host. Una
instancia de relay mantiene una sola generación activa de engine:

```text
 iPhone ─┬──▶ Relay Primary   ──▶ Engine de la Mac A ──▶ Codex
 Desktop ┘

 iPhone ─┬──▶ Relay Secondary ──▶ Engine de la Mac B ──▶ Codex
 Desktop ┘
```

Los clientes tienen perfiles Primary, Secondary y All. Eligen una instancia
por endpoint; el request actual no lleva un `hostId` para que un único relay lo
enrute. Los valores internos anteriores `personal`, `puky` y `all` permanecen
por compatibilidad.

La diferencia queda así:

| Nivel | Estado |
| --- | --- |
| Todos los clientes hablan con relays, nunca directamente con engines | Implementado |
| Varios clientes por instancia relay–engine | Implementado |
| Un cliente opera varias Macs mediante perfiles de endpoint | Implementado |
| Un único proceso de relay enruta N clientes hacia M engines por `hostId` | Objetivo, no implementado en `v0.1` |

## Qué hace cada pieza

### Cliente

Mobile y Desktop:

- usan REST para lecturas y órdenes durables;
- reciben cambios en vivo mediante Server-Sent Events (SSE);
- guardan un cursor por fuente para reanudar;
- recurren a polling acotado si SSE deja de responder; y
- guardan tokens en Keychain.

No arrancan Codex, no exponen puertos del host y no hablan con App Server. Son
ventanas reemplazables sobre la misma central.

### Relay

El relay:

- autentica requests HTTP de clientes;
- persiste una orden antes de responder que fue aceptada;
- deduplica reintentos mediante claves de idempotencia;
- guarda comandos, snapshots, eventos, alias y cursores en SQLite;
- emite eventos ordenados por SSE;
- reanuda desde un cursor o `Last-Event-ID`;
- mantiene heartbeat y lease del engine;
- rechaza escrituras de generaciones viejas mediante fencing; y
- retiene trabajo en cola si el engine se desconecta mientras el relay sigue
  disponible.

El relay no razona, no ejecuta herramientas y no tiene acceso directo al
workspace de Codex. Su trabajo es más acotado y decisivo: toma custodia de la
orden y conserva una historia recuperable.

### Engine

El engine corre en la Mac que hace el trabajo. Cada host necesita su propio
engine. Éste:

- inicia Codex App Server como proceso hijo y observa si termina;
- habla JSONL con App Server por entrada y salida estándar;
- valida versión, esquema, modelos y capacidades al iniciar;
- rechaza rutas fuera de `workspaceRoots`;
- transforma órdenes de Fermín en operaciones de threads y turns de Codex;
- persiste sesiones, comandos, eventos, cursores, epochs y leases en SQLite
  WAL;
- expone sólo sesiones administradas por Fermín;
- procesa cada sesión en un carril separado; y
- nunca publica App Server en la red.

Si App Server termina, el engine deja de declararse listo y falla de forma
visible. La recuperación completa del proceso depende del supervisor con el que
se despliegue el engine; el repositorio no afirma que una instalación sin
supervisor se reinicie sola indefinidamente.

### Codex App Server

App Server es la interfaz local de Codex. Administra threads, turns,
herramientas, sandbox, aprobaciones y ejecución. Fermín no duplica esas
funciones; el engine adapta su protocolo y mantiene esa interfaz fuera de
Internet.

## El recorrido de una orden

Ejemplo: vas caminando, enviás desde el iPhone “revisá este uso alto de CPU” y
elegís la Mac Primary.

1. Mobile genera una clave de idempotencia y hace un request al relay Primary.
2. El relay autentica y guarda la orden en SQLite.
3. Sólo después responde que fue aceptada.
4. El engine conectado recibe la orden y la persiste localmente.
5. El carril de esa sesión la traduce a una llamada de Codex App Server.
6. Los eventos resultantes vuelven al relay y quedan ordenados.
7. Mobile y Desktop reciben los eventos desde sus propios cursores.
8. Si alguno se desconecta, pide el tramo faltante al regresar.

“Aceptada” no significa “ejecutada”. Significa que el relay ya la guardó y tomó
custodia de ella. Esa distinción evita que la interfaz confunda recepción
durable con resultado final.

## Varios clientes sobre un mismo host

Un iPhone y Desktop pueden leer y escribir sobre las mismas sesiones. Cada uno
tiene su cursor, pero ambos terminan convergiendo al estado guardado por el
relay. Es la situación cotidiana que ya funciona.

Cuando llegan órdenes cercanas desde dos clientes:

- el relay persiste cada intención y le asigna una secuencia;
- la entrega conserva un orden observable; y
- el engine procesa secuencialmente el trabajo de una misma sesión.

Esto elimina varias carreras comunes, pero no promete ejecución exactamente
una vez. Si Codex recibe una orden y el engine cae antes de guardar el resultado,
la situación es ambigua. Fermín marca `unknown`, inspecciona la sesión y evita
repetir a ciegas.

## Un cliente sobre varios hosts

Hoy el routing ocurre en el cliente: Primary y Secondary apuntan a instancias
distintas. El mismo iPhone puede cambiar de perfil y operar otra Mac sin hablar
directamente con su engine.

La arquitectura N×M mueve esa selección al relay central: la orden incluye el
host y la central la entrega al engine autorizado. Eso exige identidad y
autorización por host; todavía no existe en la API pública `v0.1`.

## Las piezas que producen confianza

WebSocket sólo transporta frames. La confianza aparece porque Fermín agrega
estado y reglas de recuperación:

- **Persistencia:** relay y engine guardan antes de avanzar de etapa.
- **Idempotencia:** un retry con la misma clave representa la misma intención.
- **Guardar y reenviar (*store-and-forward*):** el relay conserva trabajo hasta
  que el engine vuelve.
- **Replay:** cada cliente continúa desde su último cursor.
- **Lease:** el relay sabe si el engine sigue vigente.
- **Fencing:** una generación nueva invalida a una conexión vieja o zombie.

Los sobres relay–engine incluyen versión de protocolo, identidad del engine,
epoch de conexión, secuencia, ACK, cursor de reanudación y generación de
fencing.

## Cuando relay y engine comparten una Mac

Es el despliegue más simple y el documentado en este repositorio. Reduce piezas,
pero comparte el dominio de falla: si la Mac se apaga, el relay deja de aceptar
órdenes y el engine deja de ejecutar.

Separarlos cambia eso:

```text
 Cliente ──▶ relay siempre disponible ──▶ engine en una Mac intermitente
```

Mientras el relay permanezca en línea puede aceptar y encolar. No puede
despertar una Mac apagada ni ejecutar sin el engine.

## Código reutilizable y despliegue privado

| Incluido | Específico del despliegue original y no publicado |
| --- | --- |
| Relay y engine | Mac siempre encendida usada como servidor |
| Conexión saliente del engine | Cuenta y dominio privados de Cloudflare |
| REST, SSE y WebSocket | Rutas elegidas para dos Macs personales |
| Replay, idempotencia, leases y fencing | Servicios personales launchd y PM2 |
| SQLite local | Rutas privadas del filesystem |
| Lista permitida de workspaces | Sesión autenticada de Codex |
| Tokens en Keychain | Tokens de producción |

Los alias `/fermin-code`, `/fermin-code-puky` y `/sync-hub` siguen en el router
por compatibilidad. Un despliegue nuevo puede usar la API sin prefijo y elegir
sus propias rutas públicas.

## La regla que sostiene todo

El relay no reemplaza a Codex y el engine no reemplaza al relay.

- Codex piensa y ejecuta.
- El engine cuida la frontera de una Mac.
- El relay toma custodia de las órdenes y de su historia.
- Los clientes permiten enviar y observar desde cualquier lugar.

Separar esas responsabilidades es lo que permite mandar una idea y dejar de
vigilar el transporte.
