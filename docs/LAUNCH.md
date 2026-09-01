# Cómo explicar Fermín

[← Documentación](README.md)

Este archivo fija el lenguaje público del proyecto. No es una hoja de ruta ni
un calendario. Sirve para explicar Fermín de forma simple, concreta y honesta.

## La idea central

Fermín es una central durable para trabajar con Codex en distintas
computadoras. Instalás el relay en una máquina suficientemente disponible y
conectás como hosts las Macs donde realmente trabaja Codex.

Después mandás órdenes desde el iPhone, Desktop u otro cliente. Todas llegan a
la misma central. El relay las guarda, identifica su destino, las deriva al host
correcto y conserva la historia de lo ocurrido.

```text
Clientes
   ↓
Relay durable
   ↓
Hosts
   ↓
Codex
```

> **Mandás una orden y dejás de vigilar el transporte.**

## Explicación general

Yo básicamente tengo una Mac en mi casa y ahí instalo una especie de central.
Esa central es el relay durable.

Le digo relay porque recibe órdenes y las reenvía. Le digo durable porque no se
limita a pasarlas en vivo: primero las guarda. Toma custodia de cada orden antes
de seguir con el proceso.

Después configuro como hosts las computadoras donde quiero trabajar. En cada
host vive un engine junto a Codex. Desde cualquier cliente mando una intención
y elijo su destino. Todos los clientes hablan con la misma central; no necesitan
conectarse directamente con cada Mac.

Si el host está disponible, el relay entrega la orden. Si está temporalmente
desconectado y el relay sigue en línea, la conserva hasta que pueda continuar.
Los eventos y resultados vuelven a la central, que guarda la historia para que
yo pueda entrar desde otro cliente y saber qué ocurrió.

## Para explicárselo a un jefe

> Fermín es una central durable para trabajar con Codex en distintas
> computadoras. Conecto mis Macs como hosts y mando órdenes desde el iPhone,
> Desktop o cualquier otro cliente. Todas llegan al mismo relay, que primero las
> guarda, después las deriva al host correcto y conserva la historia de lo
> ocurrido. El valor no es solamente el acceso remoto: es poder mandar una
> intención y confiar en que no depende de una conexión perfecta ni de que yo
> siga mirando la aplicación.

## Para explicárselo a los chicos

> Tengo una central en el medio. Le mando una orden desde cualquier lado, la
> central la guarda y se la pasa a la computadora que elegí. Si algo se corta,
> la orden no depende solamente de ese instante. Después vuelvo desde el celular
> o desde otra Mac y puedo ver qué pasó.

## La frase corta

> **Fermín es una central durable que toma custodia de mis órdenes y las hace
> llegar al host correcto.**

## La experiencia completa

> **Yo mando una idea desde cualquier lugar. Fermín la guarda, la deriva a la
> computadora correcta y conserva su historia. Por eso puedo seguir con mi vida
> confiando en que la intención no quedó perdida en el camino.**

Éste es el valor cotidiano. Podés estar caminando por la casa o yendo al kiosco,
mandar un audio desde el iPhone y seguir con lo que estabas haciendo. La
confianza elimina fricción; cuando enviar una idea deja de ser un procedimiento
técnico, aprovechás más ideas.

## Qué se puede afirmar hoy

La versión pública demuestra estas capacidades:

- los clientes hablan con el relay, nunca con el engine;
- el relay persiste órdenes y permite reanudar eventos;
- cada engine vive junto a Codex en la Mac que hace el trabajo; y
- Mobile y Desktop demuestran cómo consumir el contrato.

La arquitectura que guía el proyecto es una estrella N×M alrededor de un relay
central. La release `v0.1` usa una instancia relay–engine por host y los clientes
eligen endpoints. No la describas como un hub multi-host ya terminado.

Repositorio:

<https://github.com/GBurgardt/fermin-code>

Comprobado en la publicación original:

- lectura anónima del repositorio;
- CI de Rust, macOS e iOS;
- secret scanning y push protection;
- reporte privado de vulnerabilidades;
- imágenes públicas con contenido neutro; y
- límites de autoalojamiento documentados.

Todavía falta evidencia independiente de una instalación completa siguiendo la
guía en una tercera Mac limpia. No lo presentes como “un clic” ni como una
experiencia terminada para usuarios no técnicos.

## Comunicación pública

Los borradores quedan plegados para que este documento siga siendo fácil de
leer desde el teléfono. Abrí sólo el canal que vayas a usar.

<details>
<summary><strong>Primer anuncio: X</strong></summary>

X permite contar el origen personal y apuntar directo al código.

> Publiqué Fermín.
>
> Es la central durable que uso para mandar trabajo a Codex desde el iPhone o
> Desktop. El relay guarda cada orden antes de aceptarla, la deriva hacia la Mac
> correcta y conserva la historia para que pueda volver desde cualquier cliente.
>
> La forma que guía el proyecto es simple: N clientes, una central y M hosts.
> La versión pública actual implementa un par relay–engine por host y documenta
> ese límite sin vueltas.
>
> [github.com/GBurgardt/fermin-code](https://github.com/GBurgardt/fermin-code)

Seguimiento técnico opcional:

> El valor no es otra interfaz de chat. El relay toma custodia de la intención:
> guarda antes de aceptar, reconoce reintentos, reproduce eventos desde un
> cursor y quita autoridad a conexiones viejas. Codex sigue razonando y
> ejecutando; Fermín hace confiable el camino remoto.

</details>

<details>
<summary><strong>Show HN</strong></summary>

Las [reglas de Hacker News](https://news.ycombinator.com/newsguidelines.html)
piden no publicar texto generado o editado por IA. El autor debe escribir la
versión final con sus propias palabras.

Un post factual puede cubrir:

- el problema personal que originó Fermín;
- qué ejecuta hoy el repositorio;
- por qué Codex es el harness y el relay es la capa remota;
- persistencia, replay, fencing y cola offline;
- la diferencia entre la implementación actual y la estrella N×M; y
- qué feedback técnico se busca.

Usá un título sencillo `Show HN:`, enlazá el repositorio y no pidas votos ni
comentarios coordinados.

</details>

<details>
<summary><strong>Product Hunt</strong></summary>

La [guía oficial de Product Hunt](https://help.producthunt.com/en/articles/479557-how-to-post-a-product)
pide URL de producto, descripción, galería y material de lanzamiento; también
admite una demo. `v0.1` es una release de código para desarrolladores, sin
servicio alojado ni instalador guiado.

Decisión pragmática: **no usar Product Hunt para esta release**. Sólo tendría
sentido reevaluarlo cuando el producto real sea fácil de instalar y demostrar.
Esa condición no es un compromiso de construirlo.

</details>

No afirmes cero configuración, wake garantizado, aislamiento multiusuario,
cifrado de extremo a extremo, disponibilidad alojada ni routing multi-host en
un único relay hasta que el sistema pueda demostrarlo.

---

[← Documentación](README.md) · [Volver al repositorio →](../README.md)
