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

Escribí con la voz pública de Fermín: simple, directa, humana y pragmática.
Explicá primero el problema cotidiano y el recorrido de una orden; introducí
después la precisión técnica. Preferí ejemplos fáciles de repetir. Evitá
marketing vacío, tono corporativo, abstracciones innecesarias y promesas.

La definición base es: “Fermín es una central durable que toma custodia de tus
órdenes y las hace llegar al host correcto”. La frase de experiencia es:
“Mandás una orden y dejás de vigilar el transporte”.

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
