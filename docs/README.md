# Documentación de Fermín

[← Volver al README](../README.md)

La documentación está separada por tema. En cada documento vas a encontrar qué
hace `v0.1` hoy y qué parte pertenece al diseño futuro.

## Arquitectura

[Arquitectura](ARCHITECTURE.md)

Explica qué lugar ocupan el relay, el engine, los clientes y Codex App Server.
También sigue una orden desde que sale del cliente hasta que vuelve como evento.

## Instalación

[Autoalojamiento](SELF_HOSTING.md)

Te guía por la instalación más simple: relay, engine y Codex en una misma Mac.
Después conecta Desktop, Mobile y el acceso remoto.

## Integración

[API](API.md)

Reúne la autenticación, las rutas, los estados de una orden y la forma de volver
a conectarse sin perder eventos.

## Seguridad

[Modelo de seguridad](SECURITY_MODEL.md)

Explica qué acceso obtiene Fermín, qué controles ya existen, qué debe cuidar
quien lo instala y qué seguridad todavía no ofrece esta versión.

## Descripción pública

[Descripción pública](LAUNCH.md)

Reúne distintas formas de explicar Fermín y marca los límites que deben
mantenerse al hablar de la versión pública.

## Contribuciones

[Cómo contribuir](../CONTRIBUTING.md)

Define el alcance de cada componente, las verificaciones requeridas y las
reglas de documentación.

## Orden sugerido

Si querés conocer el proyecto de punta a punta:

1. [Arquitectura](ARCHITECTURE.md)
2. [Autoalojamiento](SELF_HOSTING.md)
3. [API](API.md)
4. [Modelo de seguridad](SECURITY_MODEL.md)

Cada documento incluye enlaces al índice y al documento siguiente.
