# Fermín

Fermín te permite trabajar con las sesiones de Codex que corren en una Mac
desde el iPhone, otra Mac o cualquier cliente conectado al relay.

El relay queda en el medio: recibe cada orden, la guarda y se la entrega al
engine, el programa que corre junto a Codex en la Mac. Codex razona, usa
herramientas y modifica el workspace. Fermín se ocupa de guardar la orden,
entregarla cuando el engine está disponible y conservar la historia para cuando
vuelvas.

[Funcionamiento](#funcionamiento) · [Topología](#topología) ·
[Instalación](#instalación) · [Documentación](#documentación)

## Funcionamiento

1. Un cliente manda una orden. Puede ser Mobile, Desktop u otra aplicación.
2. El relay verifica el token y guarda la orden.
3. El engine que corre en la Mac recibe la orden y se la pasa a Codex App
   Server.
4. Lo que ocurre vuelve al relay y queda disponible para todos los clientes.

Una orden pasa a estado `accepted` después de quedar guardada en el relay. Eso
confirma que Fermín ya la tiene, no que Codex haya terminado el trabajo.

```text
Cliente
   ↓
Relay durable
   ↓
Engine del host
   ↓
Codex App Server
```

Los clientes se conectan al relay. No se conectan directamente al engine ni a
Codex App Server.

## Topología

### Estado de `v0.1`

Hoy, cada instancia de relay trabaja con una generación activa de engine. Para
usar dos hosts, se levanta un par relay–engine por host y el cliente elige
Primary o Secondary.

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

### Arquitectura objetivo

El diseño al que apunta Fermín usa un solo relay para registrar varios hosts.
Cada orden indica dónde debe ejecutarse y el relay la entrega al engine de esa
Mac.

<a href="docs/images/architecture/relay-star-mobile.svg">
  <picture>
    <source media="(max-width: 600px)" srcset="docs/images/architecture/relay-star-mobile.svg">
    <img src="docs/images/architecture/relay-star-platform.svg" alt="Clientes conectados con distintos hosts mediante un relay durable central">
  </picture>
</a>

<sub>El diagrama representa la arquitectura objetivo. La versión `v0.1` todavía
usa un relay por host. La imagen se puede abrir en resolución completa.</sub>

La selección entre varios hosts dentro de un mismo relay todavía no está
implementada en `v0.1`. Tampoco hay una fecha comprometida para agregarla.

[Consultar la arquitectura completa](docs/ARCHITECTURE.md)

## Comportamiento ante interrupciones

- **Cerrás el cliente:** una orden ya aceptada sigue guardada en el relay. Al
  volver, el cliente recupera lo nuevo desde su cursor.
- **El cliente reintenta:** si usa la misma clave de idempotencia, el relay
  reconoce la orden y no crea otra.
- **El engine se desconecta:** el relay puede guardar el trabajo pendiente
  mientras siga disponible.
- **El engine vuelve:** leases y fencing deciden cuál es la conexión vigente y
  descartan una conexión anterior.
- **Relay y engine viven en la misma Mac:** si esa Mac queda fuera de línea, el
  relay tampoco puede recibir órdenes nuevas durante el corte.

Fermín no puede encender una Mac apagada ni prometer ejecución exactamente una
vez. Si Codex recibe una orden y el engine falla antes de guardar el resultado,
el estado puede quedar como `unknown`. En ese caso, el engine revisa la sesión
antes de decidir si debe intentarla otra vez.

## Componentes

### Relay

Es la central del sistema. Recibe solicitudes HTTP, autentica clientes, guarda
órdenes y mantiene la historia de eventos. Los clientes reciben actualizaciones
mediante Server-Sent Events (SSE) y el engine se conecta por WebSocket.

### Engine

Es el programa que corre en la Mac host, junto a Codex. Inicia Codex App Server,
comprueba que la versión sea compatible, limita las carpetas disponibles con
`workspaceRoots` y traduce las órdenes de Fermín al protocolo de Codex.

### Mobile y Desktop

Son dos formas de usar el mismo relay desde iOS y macOS. Envían operaciones por
REST, reciben eventos por SSE y guardan los tokens en Keychain. No ejecutan
Codex ni el engine.

### Codex App Server

Es la interfaz local de Codex. Administra threads, turns, herramientas,
sandbox, aprobaciones y ejecución. Se mantiene dentro de la Mac host y no se
publica directamente en Internet.

## Relación con Codex App Server

Ir directo a App Server puede alcanzar cuando el cliente, la Mac y la red van a
estar disponibles durante toda la operación. Fermín agrega una capa durable
para los casos en que alguna de esas conexiones puede cortarse:

- guarda la orden antes de responder `accepted`;
- reconoce un reintento mediante la clave de idempotencia;
- mantiene una cola si el engine se desconecta y el relay sigue disponible;
- reconstruye la historia de cada cliente desde su cursor; y
- usa leases y fencing para descartar conexiones viejas del engine.

App Server ejecuta el trabajo de Codex. Fermín cuida el camino de la orden y la
historia que queda alrededor de ese trabajo.

## Interfaces de referencia

La siguiente captura muestra el cliente Mobile con datos de demostración.

[![Fermín Mobile mostrando varias sesiones activas](docs/images/en/mobile/mobile-many-sessions.png)](docs/images/en/mobile/mobile-many-sessions.png)

<sub>La imagen se puede abrir en resolución completa.</sub>

<details>
<summary><strong>Conversación en Mobile</strong></summary>

[![Conversación remota en Fermín Mobile](docs/images/en/mobile/mobile-conversation.png)](docs/images/en/mobile/mobile-conversation.png)

</details>

<details>
<summary><strong>Cliente Desktop</strong></summary>

[![Fermín Desktop mostrando sesiones remotas](docs/images/en/desktop/desktop-main.png)](docs/images/en/desktop/desktop-main.png)

</details>

## Contenido del repositorio

- **`service/`:** relay, engine y CLI de diagnóstico escritos en Rust.
- **`desktop/`:** cliente nativo para macOS.
- **`mobile/`:** cliente nativo para iOS 17 o posterior.

Los tres componentes se pueden compilar desde el repositorio. Todavía no hay un
relay alojado ni un instalador de un paso, por lo que la instalación requiere
experiencia con macOS, Codex, TLS y manejo de tokens.

## Instalación

La instalación local más simple ejecuta relay, engine y Codex en una misma Mac.
Necesitás macOS, Rust 1.92 o posterior, Xcode Command Line Tools y un Codex CLI
compatible y autenticado. Para compilar Mobile también necesitás Xcode y
XcodeGen.

[Seguir la guía de autoalojamiento](docs/SELF_HOSTING.md)

Para verificar un componente por separado:

- [relay y engine](service/README.md);
- [cliente Desktop](desktop/README.md); o
- [cliente Mobile](mobile/README.md).

Las URLs de ejemplo usan `relay.example.com` y no son endpoints operativos.
Los tokens se configuran localmente y los clientes Apple los almacenan en
Keychain. No confirmes tokens en Git.

## Límites de `v0.1`

- Uso autoalojado para una persona.
- Una generación activa de engine por instancia de relay.
- Sin cuentas, multi-tenancy ni pairing de dispositivos.
- Sin relay alojado ni actualizaciones automáticas.
- Sin binarios notarizados para distribución pública.
- Sin cifrado de extremo a extremo del contenido.

El relay escucha sólo en loopback. El acceso remoto requiere un proxy TLS, una
red privada o un túnel saliente. Una Mac dormida o apagada no puede ejecutar
trabajo. El relay sólo puede mantener una cola si continúa disponible.

[Consultar el modelo de seguridad](docs/SECURITY_MODEL.md)

## Documentación

- [Índice de documentación](docs/README.md)
- [Arquitectura](docs/ARCHITECTURE.md)
- [Autoalojamiento](docs/SELF_HOSTING.md)
- [API](docs/API.md)
- [Modelo de seguridad](docs/SECURITY_MODEL.md)
- [Descripción pública](docs/LAUNCH.md)
- [Contribuciones](CONTRIBUTING.md)

## Licencia

Fermín usa la [licencia MIT](LICENSE).

Codex es un producto separado de OpenAI. Fermín no es un producto oficial de
OpenAI.
