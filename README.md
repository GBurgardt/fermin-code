# Fermín Code

Clientes para trabajar con Codex en una Mac propia desde el iPhone u otra Mac.
Un proyecto personal, autoalojado y experimental.

Lo construí para mi forma de trabajar: dejar varios encargos, volver a ellos
durante el día y conservar el entorno donde ya tengo preparados mis proyectos
y herramientas. A veces el pedido empieza con un audio mientras camino. Quiero
poder retomarlo después desde la computadora sin cambiar la máquina que hace
el trabajo.

Codex aporta el agente. Fermín agrega sus clientes, organización de sesiones
y una capa que guarda las órdenes antes de confirmar su recepción.

Lo comparto para que otras personas puedan probar ese recorrido, revisar el
código y decir qué les sirve. No es una afirmación de que sea nuevo, mejor que
las alternativas o adecuado para todo el mundo.

[Qué incluye](#qué-incluye) · [Instalación](#probarlo) ·
[Límites](#límites-importantes) · [Documentación](#documentación)

## Qué incluye

- **Trabajo sobre tu Mac.** Las sesiones usan sus archivos y herramientas,
  aunque las dirijas desde otro dispositivo. La Mac debe seguir disponible.
- **Varias sesiones retomables.** Los clientes ofrecen fijados e historial
  para encontrar el trabajo que querés continuar. Las sesiones paralelas no
  aíslan archivos, simuladores ni otras herramientas compartidas.
- **Preparación del pedido.** Hay un mejorador opcional con una revisión
  separada de fidelidad. Conserva el original junto a la transformación; esa
  revisión también puede equivocarse y consume uso adicional del modelo.
  La voz en Mobile requiere configuración adicional: no viene como servicio
  alojado ni con credenciales incluidas.
- **Recepción persistente.** El relay guarda la orden antes de responder
  `accepted`; los clientes pueden recuperar eventos al reconectarse. Eso no
  garantiza que toda tarea termine ni que un envío sin confirmación haya llegado.
- **Un entorno reutilizable.** Codex puede aprovechar los scripts y herramientas
  que prepares para construir, probar o desplegar. Este repositorio no incluye
  mi infraestructura privada de despliegue ni de instalación de apps.

El código público contiene `service/` (Rust), `desktop/` (macOS) y `mobile/`
(iOS). Es una edición separada de mi instalación personal; las funciones que
describo aquí corresponden a esta copia, no a todo lo que uso privadamente.

## Antes de elegir otra herramienta

También existen el [acceso remoto oficial de Codex](https://learn.chatgpt.com/docs/remote-connections)
y [Happy](https://github.com/slopus/happy). Si alguno resuelve tu recorrido
con menos configuración o mantenimiento, no necesitás añadir Fermín.

Puede interesarte este proyecto si querés revisar o adaptar esta combinación
de clientes, recepción persistente y organización. Todavía no hay una
comparación que demuestre mayor confiabilidad o productividad que las alternativas.
Estar escrito en Rust tampoco constituye por sí solo esa prueba.

## Cómo funciona

```text
iPhone / Mac cliente
        ↓
Relay: guarda órdenes y eventos
        ↓
Engine: conecta el host con Codex
        ↓
Codex App Server
        ↓
Archivos y herramientas del host
```

El relay recibe los pedidos. El engine es el proceso que los conduce hacia
Codex en la Mac de trabajo. Están separados para que recibir una orden no
dependa de que el ejecutor esté conectado en ese instante.

La instalación local más simple pone ambos en la misma Mac. Si esa Mac se
apaga, también deja de recibir pedidos. Para recibirlos mientras el host no
está disponible, el relay necesita otra máquina que siga encendida.

Cada instancia admite un engine activo. Los perfiles Primary y Secondary
permiten configurar dos pares independientes. No hay routing de varios hosts
en un único relay ni una promesa de implementarlo.

[Leer la arquitectura implementada](docs/ARCHITECTURE.md)

## Qué significa una confirmación

- `accepted`: el relay guardó la orden.
- `engineDurable`: el engine también la guardó.
- `sentToChild`: se registró el intento de entrega a Codex; una caída puede
  dejar incierto si alcanzó a ejecutarse.
- `completed`: terminó el manejo de esa operación. Para enviar un mensaje,
  puede significar que comenzó el turno, no que terminó tu tarea.
- `unknown`: hay incertidumbre. Revisá la sesión y sus efectos antes de
  repetir el pedido.

Una misma clave de idempotencia evita crear otra orden en el relay. No vuelve
idempotentes los efectos de un comando externo. No prometemos ejecución
exactamente una vez, recuperación de todos los procesos ni protección ante
pérdida del disco.

[Estados y eventos de la API](docs/API.md)

## Probarlo

Esta versión está orientada a desarrolladores capaces de operar su propia Mac,
Codex y el acceso remoto. Necesitás Rust 1.92 o posterior y Xcode Command Line
Tools. Mobile requiere Xcode completo y XcodeGen. El host necesita un Codex CLI
compatible y autenticado.

Empezá por [Autoalojamiento](docs/SELF_HOSTING.md). La guía usa dos archivos de
configuración y tres tokens separados. No instala servicios ni modifica tu
configuración de Codex.

**Leé primero el [modelo de seguridad](docs/SECURITY_MODEL.md).** Esta versión
usa `approvalPolicy=never`, no ofrece aprobaciones interactivas y hereda el
sandbox efectivo de Codex en el host. `workspaceRoots` restringe las rutas que
acepta el adaptador; no encierra todas las herramientas dentro de esas carpetas.

No hay instalador de un paso, relay alojado ni binarios públicos notarizados.
Las URLs de ejemplo son deliberadamente inoperantes. No distribuyas tokens ni
credenciales de proveedores dentro de una app pública.

## Referencias visuales

Estas imágenes usan contenido de demostración. Fueron regeneradas a partir de
referencias y no son evidencia de una sesión real ni de cada detalle del estado
actual. [Procedencia](docs/images/README.md).

[![Referencia de Mobile con varias sesiones](docs/images/en/mobile/mobile-many-sessions.png)](docs/images/en/mobile/mobile-many-sessions.png)

La imagen se puede abrir en resolución completa.

<details>
<summary>Referencia de Desktop</summary>

[![Referencia del cliente Desktop](docs/images/en/desktop/desktop-main.png)](docs/images/en/desktop/desktop-main.png)

La imagen se puede abrir en resolución completa.

</details>

## Límites importantes

- Diseñado para una persona; sin cuentas, pairing ni aislamiento multi-tenant.
- Sin cifrado de extremo a extremo del contenido. Protegé red, tokens y discos.
- Sin paridad garantizada con todas las funciones del cliente oficial de Codex.
  Las solicitudes de aprobación se rechazan y las preguntas estructuradas
  reciben una respuesta vacía; no las tomes como consentimiento humano.
- Sin supervisor instalado automáticamente, actualizaciones automáticas,
  disponibilidad garantizada ni vencimiento general de órdenes demoradas.
- El uso de modelos y otros servicios depende de tus cuentas y sus condiciones;
  la licencia del código no incluye ese servicio.

Las pruebas automatizadas cubren mecanismos concretos. No sustituyen una prueba
de instalación completa en una Mac independiente ni certifican disponibilidad
de producción. El proyecto se mantiene a partir del uso personal, sin plazos de
soporte o roadmap comprometidos.

## Qué comentarios me sirven

Contame qué intentaste, dónde dejó de ser claro y qué alternativa te resultó
más cómoda. Una instalación que no se puede reproducir o un estado que promete
demasiado son problemas útiles para revisar. No hace falta agregar funciones
para que una contribución tenga valor.

[Cómo contribuir](CONTRIBUTING.md) · [Reportar una vulnerabilidad en privado](SECURITY.md)

## Documentación

- [Índice](docs/README.md)
- [Arquitectura](docs/ARCHITECTURE.md)
- [Autoalojamiento](docs/SELF_HOSTING.md)
- [API](docs/API.md)
- [Seguridad](docs/SECURITY_MODEL.md)
- [Cómo compartir el proyecto](docs/LAUNCH.md)

## Licencia

[MIT](LICENSE). Codex es un producto separado de OpenAI. Fermín Code no es un
producto oficial de OpenAI.
