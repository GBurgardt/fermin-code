# Imágenes públicas

## Arquitectura

| Imagen | Uso | Origen |
| --- | --- | --- |
| `architecture/relay-star-platform.png` | Una central durable conecta N clientes con M hosts | Generada y ajustada con Imagegen integrado; revisada visualmente |

La ilustración de arquitectura es sintética. Usa fondo opaco y contenido
genérico. No contiene capturas, rutas, sesiones, hostnames ni identificadores
reales. Muestra conexiones cliente↔relay y engine↔relay; deliberadamente no
dibuja conexiones directas cliente→engine.

## Capturas de producto

| Vista | Referencia local privada | Imagen pública en inglés |
| --- | --- | --- |
| Conversación Mobile | `originals/mobile/IMG_4874.PNG` | `en/mobile/mobile-conversation.png` |
| Lista Mobile | `originals/mobile/IMG_4875.PNG` | `en/mobile/mobile-sessions.png` |
| Carga activa Mobile | `originals/mobile/mobile-many-sessions.png` | `en/mobile/mobile-many-sessions.png` |
| Lista Desktop | `originals/desktop/desktop-live-main.png` | `en/desktop/desktop-main.png` |
| Conversación Desktop | `originals/desktop/desktop-conversation.png` | `en/desktop/desktop-conversation.png` |

Los archivos bajo `originals/` están ignorados y no forman parte de Git. Las
referencias Mobile fueron aportadas por el propietario. Las de Desktop se
obtuvieron de la app de desarrollo.

## Por qué las capturas públicas son demostraciones

Los originales contenían títulos de sesiones, fragmentos de conversaciones,
rutas y un identificador real. Traducir sólo el idioma habría conservado datos
operativos privados.

Por eso se regeneraron desde las referencias privadas. Mantienen la dirección
visual oscura y una disposición representativa, pero usan contenido neutro en
inglés. Son ilustraciones del producto, no evidencia píxel por píxel de una
sesión real.

Durante la revisión de identidad pública, Imagegen integrado reemplazó
únicamente las etiquetas visibles `Fermín Engine` por `Fermín` en las cuatro
capturas que las contenían. También volvió más directa la redacción del diagrama
sin cambiar su topología. Se revisaron composición, dimensiones y contenido
después de cada edición. La captura de conversación Mobile conserva `FERMÍN`
porque identifica al participante.

Tamaños:

- conversación Mobile: 853 × 1844;
- carga activa Mobile: 853 × 1844;
- lista Mobile: 852 × 1846;
- imágenes Desktop: 1587 × 991; y
- arquitectura: 1672 × 941.

Antes de publicar se revisaron credenciales, endpoints, rutas personales,
identificadores de sesión y metadata.
