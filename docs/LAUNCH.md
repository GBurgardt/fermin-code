# Descripción pública

[← Documentación](README.md)

Este documento reúne formas claras de explicar Fermín. No es una hoja de ruta
ni un calendario de producto.

## Definición

Fermín te permite trabajar con las sesiones de Codex que corren en una Mac
desde el iPhone, otra Mac o cualquier cliente conectado al relay.

El relay queda en el medio. Recibe cada orden, la guarda y se la entrega al
engine de la Mac. Después conserva lo que ocurrió para que cualquier cliente
pueda volver a esa historia.

```text
Cliente
   ↓
Relay durable
   ↓
Engine del host
   ↓
Codex App Server
```

Codex piensa y ejecuta el trabajo. Fermín cuida el camino de la orden y la
historia que queda alrededor.

## Descripción general

Podés ejecutar el relay en una Mac o en otro servidor que esté disponible. Cada
Mac que ejecuta Codex necesita su propio engine, un programa local que conecta
esa Mac con el relay.

Los clientes hablan siempre con el relay, nunca directamente con el engine.
Cuando mandás una orden, el relay:

1. verifica el token;
2. guarda la orden;
3. se la entrega al engine cuando está disponible; y
4. conserva los eventos para que los clientes sepan qué ocurrió.

Le decimos *durable* porque guarda la orden antes de responder `accepted`. No se
limita a pasar datos mientras una conexión está abierta.

## Resumen ejecutivo

> Fermín permite trabajar con las sesiones de Codex de una Mac desde Mobile,
> Desktop u otro cliente. Todos hablan con un relay autoalojado que guarda cada
> orden antes de aceptarla, se la entrega al engine de la Mac y conserva lo que
> ocurrió. Así los clientes pueden reintentar, desconectarse y volver sin
> publicar Codex App Server directamente en Internet.

## Explicación no técnica

> Fermín pone una central entre tus dispositivos y la Mac donde trabaja Codex.
> Mandás una orden, la central la guarda y se la pasa a esa Mac. Si cerrás el
> cliente o perdés la conexión, después podés volver y ver qué ocurrió.

## Definición breve

> **Fermín guarda las órdenes que mandás desde tus clientes y se las entrega a
> la Mac donde corre Codex.**

## Resultado operativo

Podés mandar una orden desde Mobile, cerrar la app y recuperar los eventos más
tarde. Cuando el relay responde `accepted`, la orden ya quedó guardada.

Para que esto funcione se tienen que cumplir dos condiciones:

- el relay tiene que seguir disponible para recibir órdenes nuevas; y
- el host tiene que volver a conectarse para que Codex ejecute el trabajo
  pendiente.

Fermín no enciende una Mac apagada y no sustituye la política de sandbox y
aprobaciones de Codex.

## Capacidades verificables en `v0.1`

- Los clientes se conectan al relay, no al engine.
- El relay guarda órdenes y eventos.
- Una clave de idempotencia permite reintentar sin crear otra orden.
- Cada cliente recuerda su cursor y retoma la historia desde ahí.
- Leases y fencing evitan que una conexión vieja del engine siga teniendo
  autoridad.
- El engine se ejecuta junto a Codex en la Mac host.
- Mobile y Desktop implementan el contrato del relay.

La versión `v0.1` usa una instancia relay–engine por host. Los clientes eligen
entre endpoints Primary y Secondary.

## Arquitectura objetivo

El diseño futuro registra varios hosts en un mismo relay. Cada orden indica en
qué host debe ejecutarse y el relay selecciona el engine correspondiente.

Para hacerlo bien hacen falta identidad, autorización, almacenamiento y fencing
por host. No está implementado en `v0.1` y no tiene una fecha de entrega
publicada.

## Capacidades no incluidas

La versión actual no incluye:

- instalación de un paso;
- relay alojado;
- routing multi-host en una instancia;
- cuentas o aislamiento multi-tenant;
- wake garantizado de una Mac;
- disponibilidad continua;
- cifrado de extremo a extremo; o
- distribución binaria firmada y notarizada.

## Estado de la publicación

Repositorio:

<https://github.com/GBurgardt/fermin-code>

La publicación incluye:

- código del relay, engine, Mobile y Desktop;
- CI para Rust, macOS e iOS;
- secret scanning y push protection;
- reporte privado de vulnerabilidades;
- imágenes con contenido de demostración; y
- límites de autoalojamiento documentados.

Todavía falta una prueba independiente de la guía completa en una tercera Mac
sin configuración previa.

## Canales de publicación

Los textos siguientes son borradores factuales. Deben actualizarse si cambia el
estado del repositorio.

<details>
<summary><strong>X</strong></summary>

> Publiqué Fermín `v0.1` como proyecto open source.
>
> Me permite trabajar con las sesiones de Codex de una Mac desde el iPhone u
> otra Mac. Incluye un relay durable, un engine local y clientes para iOS y
> macOS.
>
> El relay guarda cada orden antes de aceptarla y conserva la historia para que
> los clientes puedan desconectarse y volver. La versión actual usa un par
> relay–engine por host.
>
> [github.com/GBurgardt/fermin-code](https://github.com/GBurgardt/fermin-code)

</details>

<details>
<summary><strong>Show HN</strong></summary>

Las [reglas de Hacker News](https://news.ycombinator.com/newsguidelines.html)
piden no publicar texto generado o editado por IA. El autor debe redactar la
versión final.

El post puede documentar:

- el problema técnico;
- la separación entre relay, engine y Codex App Server;
- persistencia, replay, idempotencia y fencing;
- el alcance de `v0.1`;
- la arquitectura objetivo; y
- el tipo de revisión técnica solicitada.

Usá un título descriptivo con el prefijo `Show HN:`. No pidas votos ni
comentarios coordinados.

</details>

<details>
<summary><strong>Product Hunt</strong></summary>

La [guía oficial de Product Hunt](https://help.producthunt.com/en/articles/479557-how-to-post-a-product)
requiere una URL de producto, descripción, galería y material de lanzamiento.

`v0.1` es un repositorio para desarrolladores. No incluye servicio alojado ni
instalación guiada. Product Hunt no es un canal adecuado para esta versión.
Esta evaluación puede revisarse si cambia el producto; no constituye un
compromiso de desarrollo.

</details>

---

[← Documentación](README.md) · [Volver al repositorio →](../README.md)
