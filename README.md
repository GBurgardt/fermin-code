# Fermín

**Una central durable que toma custodia de tus órdenes y las hace llegar al
host correcto.**

Fermín nació de una necesidad concreta: tener una idea lejos de la computadora,
mandarla desde el iPhone y seguir con el día sin preguntarse si llegó, si quedó
duplicada o si después se podrá recuperar lo ocurrido.

> **Mandás una orden y dejás de vigilar el transporte.**

Codex sigue siendo quien razona, usa herramientas y modifica el workspace.
Fermín se ocupa del camino: recibe la intención, la guarda, la deriva hacia la
Mac indicada y conserva su historia.

![Una central durable conecta clientes con los hosts donde trabaja Codex](docs/images/architecture/relay-star-platform.png)

## La explicación simple

Instalás el relay durable en una Mac de tu casa, en un servidor pequeño o en
cualquier computadora suficientemente disponible. Después conectás como hosts
las Macs donde querés trabajar con Codex. En cada host vive un engine junto a
Codex.

Desde el iPhone, Desktop u otra aplicación enviás una orden y elegís su destino.
Todos los clientes hablan con la misma central; ninguno necesita conectarse
directamente con cada computadora.

```text
Mis clientes → Relay durable → Mis hosts → Codex
```

Hay tres piezas:

- **Cliente:** expresa la intención y muestra qué ocurrió. Mobile y Desktop son
  dos clientes de referencia.
- **Relay durable:** ocupa el centro. Recibe, autentica, guarda, ordena, deriva
  y permite retomar.
- **Engine:** vive en la Mac que hace el trabajo. Entrega la orden a Codex y
  limita qué workspaces puede tocar.

El relay y el engine pueden compartir una Mac, pero siguen siendo piezas
distintas. También pueden vivir separados: una central siempre disponible y
varias Macs conectadas como hosts.

## Qué ocurre con una orden

Cuando enviás una orden, Fermín sigue un recorrido concreto:

1. El cliente indica la intención y el destino.
2. El relay la autentica y la guarda.
3. Sólo después responde que fue aceptada.
4. La entrega al engine correspondiente cuando está disponible.
5. El engine la persiste y la pasa a Codex App Server.
6. Los eventos y el resultado vuelven al relay.
7. Cada cliente recupera la historia desde su propio cursor.

“Aceptada” no significa “ejecutada”. Significa que el relay ya tomó custodia de
la orden. Esa diferencia permite reintentar sin inventar otra intención y saber
en qué etapa quedó el trabajo.

Por eso el relay no es solamente un router. Un router elige un destino y envía.
El relay durable además guarda la orden, asume responsabilidad por ella y
conserva lo ocurrido.

## Una central, muchos clientes y muchos hosts

La forma que guía el proyecto es una estrella:

```text
 iPhone ─────┐                         ┌───── Engine en una Mac ─── Codex
 Desktop ────┼──── Relay durable ──────┼───── Engine en otra Mac ─ Codex
 Otra app ───┘                         └───── Engine M ──────────── Codex
```

Los clientes conocen al relay. Los engines conocen al relay. No hay conexiones
directas cliente→engine. Expresado técnicamente, son N clientes, un hub lógico y
M hosts.

### Qué funciona hoy y qué describe la arquitectura objetivo

La versión pública `v0.1` ya permite varios clientes sobre una misma fuente y
dos Macs mediante perfiles Primary y Secondary. Cada perfil apunta a su propio
par relay–engine.

| | Implementado en `v0.1` | Arquitectura objetivo |
| --- | --- | --- |
| Relación relay–engine | Un engine activo por instancia de relay | Un relay central deriva hacia varios hosts |
| Selección de Mac | El cliente elige un perfil y endpoint | Cada orden identifica su host de destino |
| Varios clientes | Sí, pueden observar y escribir sobre una misma fuente | Sí |
| Routing multi-host dentro de un único relay | No | Es la forma N×M que guía el diseño |

La columna derecha no es una función existente ni una fecha prometida. Explica
con honestidad la arquitectura que queremos completar sin fingir que ya está en
el código.

## El valor real

Podés estar caminando por la casa, yendo al kiosco o lejos de la Mac correcta.
Se te ocurre algo, mandás un audio o una orden desde el iPhone y seguís con tu
vida.

No tenés que quedarte mirando:

- si Internet se cortó justo en ese momento;
- si la aplicación quedó abierta;
- si la orden llegó;
- si un reintento la envió dos veces;
- si la computadora estaba conectada; o
- si después vas a poder recuperar lo ocurrido.

El relay convierte esa preocupación en infraestructura. Primero guarda la
intención. Después la hace llegar al lugar correcto. Finalmente conserva la
historia para que puedas volver desde otro dispositivo y encontrar el estado
correcto.

Esa confianza elimina fricción. Cuando mandar una idea deja de ser un pequeño
procedimiento técnico, aprovechás ideas que antes habrías dejado pasar por no
estar sentado frente a la computadora indicada.

## Por qué no conectar el cliente directamente con Codex

Una conexión directa con Codex App Server sirve cuando el cliente y la Mac
están disponibles al mismo tiempo y la red es estable. Fermín agrega las piezas
que necesita el uso remoto cotidiano:

1. Persiste la orden antes de aceptarla.
2. Usa idempotencia para que un reintento no cree otra orden.
3. Conserva trabajo si el relay sigue disponible aunque el host se desconecte.
4. Reproduce eventos desde el cursor de cada cliente.
5. Usa leases y fencing para quitar autoridad a conexiones viejas.

Si relay y engine viven en la misma Mac y esa Mac se apaga, ambos quedan fuera
de línea y no pueden aceptar trabajo nuevo. Si el relay vive en otra máquina
disponible, puede seguir tomando custodia de órdenes mientras la Mac de trabajo
está desconectada.

## Qué contiene este repositorio

| Carpeta | Contenido |
| --- | --- |
| `service/` | Relay en Rust, engine para Mac y CLI de diagnóstico |
| `desktop/` | Cliente nativo para macOS |
| `mobile/` | Cliente nativo para iOS 17 o posterior |

Las tres superficies tienen código compilable. El repositorio no incluye un
relay alojado ni un instalador de consumo de un clic. Está dirigido hoy a
desarrolladores capaces de configurar macOS, Codex, ingreso TLS y tokens
privados.

![Cliente Desktop de Fermín mostrando sesiones remotas](docs/images/en/desktop/desktop-main.png)

<p align="center">
  <img src="docs/images/en/mobile/mobile-many-sessions.png" width="260" alt="Cliente Mobile de Fermín mostrando varias sesiones activas">
  &nbsp;&nbsp;
  <img src="docs/images/en/mobile/mobile-conversation.png" width="260" alt="Cliente Mobile de Fermín mostrando una conversación">
</p>

## Ejecutar el código

Necesitás:

- macOS con Xcode Command Line Tools;
- Xcode completo para Mobile;
- Rust 1.92 o posterior;
- XcodeGen; y
- un Codex CLI compatible y ya autenticado en la Mac host.

Probar y compilar el servicio Rust:

```bash
cd service
cargo test --locked
cargo build --release
```

Probar y ejecutar Desktop:

```bash
cd desktop
swift test
swift run FerminCode
```

Generar el proyecto Mobile:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

Las URLs incluidas usan `relay.example.com` y no funcionan. Reemplazalas por
tus endpoints. Desktop lee `FERMIN_CODE_PRIMARY_RELAY_URL` y
`FERMIN_CODE_SECONDARY_RELAY_URL`; Mobile usa los valores equivalentes en
`mobile/project.yml`.

Ingresá los tokens desde las apps. Se guardan en Keychain. Nunca los confirmes
en Git.

Para el montaje completo, seguí [Autoalojamiento](docs/SELF_HOSTING.md).

## Límites actuales

- Una instancia de relay está diseñada para una persona y una generación
  activa de engine.
- El relay escucha sólo en loopback. Para acceso remoto necesitás un proxy TLS,
  una red privada o un túnel saliente.
- Los perfiles integrados se llaman Primary y Secondary. Los valores internos
  anteriores `personal` y `puky` siguen en el protocolo por compatibilidad.
- Una Mac dormida, apagada o desconectada no puede ejecutar trabajo. El relay
  puede encolar sólo si sigue disponible.
- No se publican dominios, tokens, datos de firma, rutas, servicios launchd,
  procesos PM2 ni archivos de Cloudflare del despliegue original.
- No hay cuentas, aislamiento multi-tenant, pairing de dispositivos,
  actualizaciones automáticas, binarios notarizados, relay alojado ni cifrado
  de extremo a extremo.
- No hay todavía un hub multi-host en una sola instancia.

Son hechos de la versión actual, no una hoja de ruta.

## Documentación

- [Arquitectura](docs/ARCHITECTURE.md)
- [Autoalojamiento](docs/SELF_HOSTING.md)
- [API](docs/API.md)
- [Modelo de seguridad](docs/SECURITY_MODEL.md)
- [Cómo explicar el proyecto](docs/LAUNCH.md)
- [Origen de las imágenes](docs/images/README.md)
- [Cómo contribuir](CONTRIBUTING.md)
- [Reportar vulnerabilidades](SECURITY.md)

## Licencia

Fermín usa la [licencia MIT](LICENSE).

Codex es un producto separado de OpenAI. Fermín no es un producto oficial
de OpenAI.
