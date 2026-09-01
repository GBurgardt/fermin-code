# Arquitectura: una central y varios hosts

[← Documentación](README.md)

## La idea

La arquitectura cabe en cuatro escalones:

```text
Clientes
   ↓
Relay durable
   ↓
Hosts
   ↓
Codex
```

El cliente expresa una intención. El relay toma custodia. El engine de la Mac
indicada entrega la orden a Codex. Después, los eventos vuelven al relay para
que cualquier cliente pueda retomar desde el estado correcto.

- **Codex** razona y ejecuta.
- **El engine** vive junto a Codex y cuida la frontera local.
- **El relay durable** recibe, guarda, ordena y deriva.
- **Mobile y Desktop** muestran dos formas de usar el mismo contrato.

No es escritorio remoto: circulan órdenes y eventos estructurados, no píxeles.

## La estrella

<a href="images/architecture/relay-star-mobile.svg">
  <picture>
    <source media="(max-width: 600px)" srcset="images/architecture/relay-star-mobile.svg">
    <img src="images/architecture/relay-star-platform.png" alt="N clientes conectados con M hosts mediante un relay durable central">
  </picture>
</a>

<sub>Tocá el diagrama para verlo en tamaño completo.</sub>

Las conexiones directas cliente→engine no forman parte del modelo. El cliente
habla con la central y expresa el destino. Cada engine conoce al relay y abre
hacia él una conexión saliente autenticada.

Esto evita construir una red de conexiones particulares. El relay concentra el
registro durable; cada engine conserva las llaves de su Mac; Codex conserva el
razonamiento y las herramientas.

## Qué existe hoy

La versión pública `v0.1` todavía no reúne varios hosts dentro de un único
proceso de relay. Cada instancia mantiene una generación activa de engine.

```text
Primary
  clientes
     ↓
  relay → engine → Codex

Secondary
  clientes
     ↓
  relay → engine → Codex
```

Mobile y Desktop tienen perfiles Primary, Secondary y All. Eligen una
instancia por endpoint. El request actual no lleva un `hostId` para que una
única central decida entre varios engines.

### Ya está implementado

- Todos los clientes hablan con relays, nunca directamente con engines.
- Varios clientes pueden compartir una instancia relay–engine.
- Un cliente puede operar dos Macs mediante perfiles de endpoint.
- Cada cliente conserva su propio cursor y puede retomar eventos.

### Es la forma objetivo

- Un único relay central registra varios hosts.
- Cada orden identifica el host de destino.
- El relay autoriza y deriva la orden al engine correcto.
- Cada host conserva su propia lease y generación de fencing.

La segunda lista no es una función existente ni una fecha prometida. Explica la
forma que guía el diseño sin fingir que ya está completa.

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

### Relay durable

El relay:

- autentica requests HTTP de clientes;
- guarda una orden antes de responder que fue aceptada;
- reconoce reintentos mediante claves de idempotencia;
- conserva comandos, snapshots, eventos, alias y cursores en SQLite;
- emite eventos ordenados por SSE;
- reanuda desde un cursor o `Last-Event-ID`;
- mantiene heartbeat y lease del engine;
- rechaza escrituras de generaciones viejas mediante fencing; y
- conserva trabajo si el engine se desconecta mientras el relay sigue en
  línea.

El relay no razona, no ejecuta herramientas y no tiene acceso directo al
workspace. Su responsabilidad es más acotada: toma custodia de la orden y
mantiene una historia recuperable.

### Engine

El engine corre en la Mac que hace el trabajo. Cada host necesita el suyo.

- Inicia Codex App Server como proceso hijo y observa si termina.
- Habla JSONL con App Server por entrada y salida estándar.
- Valida versión, esquema, modelos y capacidades al iniciar.
- Rechaza rutas fuera de `workspaceRoots`.
- Traduce órdenes de Fermín a threads y turns de Codex.
- Guarda sesiones, comandos, eventos, cursores, epochs y leases en SQLite WAL.
- Expone sólo sesiones administradas por Fermín.
- Procesa cada sesión en un carril separado.
- Mantiene App Server fuera de la red.

Si App Server termina, el engine deja de declararse listo y falla de forma
visible. La recuperación completa depende del supervisor usado para desplegar
el engine. El repositorio no promete que una instalación sin supervisor se
reinicie sola indefinidamente.

### Codex App Server

App Server es la interfaz local de Codex. Administra threads, turns,
herramientas, sandbox, aprobaciones y ejecución. Fermín no duplica esas
funciones; el engine adapta el protocolo y mantiene esa interfaz fuera de
Internet.

## El recorrido de una orden

Ejemplo: vas caminando, enviás desde el iPhone “revisá este uso alto de CPU” y
elegís Primary.

1. Mobile genera una clave de idempotencia y llama al relay Primary.
2. El relay autentica y guarda la orden en SQLite.
3. Sólo después responde que fue aceptada.
4. El engine conectado recibe la orden y la guarda localmente.
5. El carril de esa sesión la traduce para Codex App Server.
6. Los eventos vuelven al relay y quedan ordenados.
7. Mobile y Desktop los reciben desde sus propios cursores.
8. Si alguno se desconecta, pide el tramo faltante al regresar.

“Aceptada” no significa “ejecutada”. Significa que el relay ya tomó custodia.
Esa distinción evita confundir recepción durable con resultado final.

## Varios clientes sobre un host

Un iPhone y Desktop pueden leer y escribir sobre las mismas sesiones. Cada uno
tiene su cursor, pero ambos convergen al estado guardado por el relay. Esa
situación ya funciona.

Cuando llegan órdenes cercanas desde dos clientes, el relay persiste cada
intención, asigna una secuencia y mantiene un orden observable. El engine
procesa secuencialmente el trabajo de una misma sesión.

Esto reduce carreras, pero no promete ejecución exactamente una vez. Si Codex
recibe una orden y el engine cae antes de guardar el resultado, la situación es
ambigua. Fermín marca `unknown`, inspecciona la sesión y evita repetir a ciegas.

## Un cliente sobre varios hosts

Hoy la selección ocurre en el cliente: Primary y Secondary apuntan a instancias
distintas. El mismo iPhone puede cambiar de perfil y operar otra Mac sin hablar
directamente con su engine.

La estrella N×M mueve esa selección al relay central: la orden incluye el host
y la central la entrega al engine autorizado. Eso exige identidad y
autorización por host; todavía no existe en la API pública `v0.1`.

## Las piezas que producen confianza

WebSocket transporta frames. La confianza aparece porque Fermín agrega estado
y reglas de recuperación.

### Persistencia

Relay y engine guardan antes de avanzar de etapa. Un mensaje no depende sólo
del instante en que cruzó la red.

### Idempotencia

Un reintento con la misma clave representa la misma intención. No crea otra
orden por accidente.

### Guardar y reenviar

Si el relay sigue disponible, conserva el trabajo hasta que el engine vuelve.
No despierta una Mac apagada; evita que la intención desaparezca.

### Replay

Cada cliente continúa desde su último cursor. iPhone y Desktop pueden haberse
desconectado en momentos distintos y terminar en la misma historia.

### Lease y fencing

La lease muestra si el engine sigue vigente. El fencing quita autoridad a una
conexión vieja cuando aparece una generación nueva.

Los sobres relay–engine incluyen versión de protocolo, identidad del engine,
epoch de conexión, secuencia, ACK, cursor de reanudación y generación de
fencing.

## Cuando relay y engine comparten una Mac

Es el despliegue más corto. Reduce piezas, pero comparte el punto de falla: si
la Mac se apaga, el relay deja de aceptar órdenes y el engine deja de ejecutar.

Separarlos cambia el resultado:

```text
Cliente
   ↓
Relay disponible
   ↓
Engine en una Mac intermitente
```

Mientras el relay siga en línea puede aceptar y encolar. No puede despertar una
Mac apagada ni ejecutar sin el engine.

## Qué se publica y qué queda afuera

El repositorio incluye relay, engine, conexión saliente, REST, SSE, WebSocket,
replay, idempotencia, leases, fencing, SQLite y límites por `workspaceRoots`.

No publica la Mac siempre encendida del despliegue original, cuentas o dominios
privados, rutas de Cloudflare, servicios personales, rutas del filesystem,
tokens ni la sesión autenticada de Codex.

Los alias `/fermin-code`, `/fermin-code-puky` y `/sync-hub` siguen en el router
por compatibilidad. Una instalación nueva puede usar la API sin prefijo y
elegir sus propias rutas públicas.

## La regla que sostiene todo

- Codex piensa y ejecuta.
- El engine cuida la frontera de una Mac.
- El relay toma custodia de las órdenes y de su historia.
- Los clientes permiten enviar y observar desde cualquier lugar.

Separar esas responsabilidades es lo que permite mandar una idea y dejar de
vigilar el transporte.

---

[← Documentación](README.md) · [Siguiente: Autoalojamiento →](SELF_HOSTING.md)
