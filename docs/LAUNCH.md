# Descripción pública

[← Documentación](README.md)

Este documento define cómo describir Fermín. No es una hoja de ruta ni un
calendario de producto.

## Definición

Fermín es un sistema autoalojado para operar sesiones de Codex en una Mac
remota. Los clientes envían órdenes a un relay durable. El relay las persiste,
las entrega al engine correspondiente y conserva los eventos resultantes.

```text
Cliente
   ↓
Relay durable
   ↓
Engine del host
   ↓
Codex App Server
```

Codex realiza el razonamiento y la ejecución. Fermín administra el transporte,
la persistencia y la recuperación del estado remoto.

## Descripción general

El relay puede ejecutarse en una Mac o en otro servidor disponible. Cada Mac
que ejecuta Codex necesita un engine local.

Los clientes se conectan al relay y no al engine. Cuando un cliente envía una
orden, el relay:

1. autentica la solicitud;
2. persiste la orden;
3. la entrega al engine cuando está disponible; y
4. conserva los eventos para que los clientes recuperen el estado.

El término *durable* indica que la orden se guarda antes de confirmar su
aceptación. El relay no se limita a reenviar datos durante una conexión activa.

## Resumen ejecutivo

> Fermín permite operar sesiones de Codex que se ejecutan en una Mac remota.
> Mobile, Desktop u otro cliente envían órdenes a un relay autoalojado. El
> relay persiste cada orden, la entrega al engine del host y conserva los
> eventos. Esto permite reintentar, reconectar clientes y recuperar el estado
> sin publicar Codex App Server directamente en Internet.

## Explicación no técnica

> Fermín coloca una central entre los dispositivos del usuario y la computadora
> que ejecuta Codex. La central guarda cada orden y la entrega a la computadora
> configurada. Si el cliente se desconecta, puede volver y consultar lo que
> ocurrió.

## Definición breve

> **Fermín es un relay autoalojado que persiste órdenes y las entrega a una Mac
> que ejecuta Codex.**

## Resultado operativo

Un usuario puede enviar una orden desde Mobile, cerrar el cliente y recuperar
los eventos más tarde. Después de que el relay responde `accepted`, la orden
ya está persistida.

Este comportamiento está sujeto a dos condiciones:

- el relay debe continuar disponible para aceptar órdenes nuevas; y
- el host debe volver a conectarse para que Codex ejecute trabajo pendiente.

Fermín no enciende una Mac apagada y no sustituye la política de sandbox y
aprobaciones de Codex.

## Capacidades verificables en `v0.1`

- Los clientes se conectan al relay, no al engine.
- El relay persiste órdenes y eventos.
- Las claves de idempotencia permiten reintentos sin crear otra orden.
- Cada cliente puede reanudar eventos desde su cursor.
- Leases y fencing controlan la autoridad de la conexión del engine.
- El engine se ejecuta junto a Codex en la Mac host.
- Mobile y Desktop implementan el contrato del relay.

La versión `v0.1` usa una instancia relay–engine por host. Los clientes eligen
entre endpoints Primary y Secondary.

## Arquitectura objetivo

La arquitectura objetivo registra varios hosts en un relay. Cada orden indica
el host de destino y el relay selecciona el engine autorizado.

Esta capacidad requiere identidad, autorización, almacenamiento y fencing por
host. No está implementada en `v0.1` y no tiene una fecha de entrega publicada.

## Capacidades no incluidas

No describas la versión actual como si incluyera:

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

> Fermín `v0.1` está disponible como proyecto open source.
>
> Es un sistema autoalojado para operar sesiones de Codex en una Mac remota.
> Incluye un relay durable, un engine local y clientes para iOS y macOS.
>
> El relay persiste las órdenes antes de aceptarlas y conserva los eventos para
> reconexión y replay. La versión actual usa un par relay–engine por host.
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
