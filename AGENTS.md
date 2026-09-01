# Guía para agentes

Este repositorio público de Fermín tiene tres superficies activas:
`service/` (relay y engine), `desktop/` (cliente macOS) y `mobile/`
(cliente iOS).

Mantené explícita la frontera: Codex App Server razona y ejecuta; Fermín toma
custodia de las órdenes y de su historia. Todos los clientes se conectan al
relay, nunca directamente al engine.

La arquitectura objetivo es una estrella N×M. El código `v0.1` admite una
generación activa de engine por instancia de relay. No documentes routing
multi-host en una sola instancia como si ya estuviera implementado.

Escribí la documentación con tono neutral, preciso y sobrio. Empezá por la
definición, el alcance y el comportamiento observable. Documentá después los
requisitos, límites y procedimientos. Usá ejemplos sólo cuando aclaren una
operación concreta. Evitá historias personales, slogans, metáforas, preguntas
retóricas, entusiasmo promocional y promesas.

Usá presente indicativo para describir el sistema e imperativo para los pasos de
instalación. Separá siempre capacidad implementada, arquitectura objetivo y
capacidad no incluida. No describas un beneficio sin indicar el mecanismo y las
condiciones que lo hacen posible.

La documentación pública es mobile-first. El README debe entenderse a 390 px
sin zoom ni scroll horizontal. Preferí listas apiladas antes que tablas anchas,
diagramas verticales antes que ASCII horizontal y bloques desplegables para
material secundario. Cada imagen informativa necesita texto alternativo, una
explicación cercana y un enlace a la resolución completa.

La definición base es: “Fermín es un sistema autoalojado para operar sesiones de
Codex en una Mac remota. El relay persiste las órdenes y el engine local las
entrega a Codex”.

No agregues secretos de proveedores, tokens, identidades de firma, dominios de
producción, hostnames privados ni rutas personales.

Antes de cambiar un componente:

- Service: `cargo fmt --check && cargo test`
- Desktop: `swift test`
- Mobile: `xcodegen generate` y una build de simulador sin firma

El identificador interno `puky` permanece sólo por compatibilidad con el
protocolo actual de dos perfiles. La documentación pública y el texto nuevo de
UI deben usar Primary y Secondary, salvo al explicar esa migración.

Los archivos fuente son autoritativos. Proyectos de Xcode generados, builds,
estado SQLite, TOML local, certificados, perfiles y `Secrets.plist` deben
seguir sin trackear.
