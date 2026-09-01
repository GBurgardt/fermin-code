# Imágenes públicas

[← Documentación](../README.md)

Las imágenes públicas usan contenido de demostración. No muestran tokens,
endpoints privados, rutas personales, identificadores reales ni conversaciones
del despliegue original.

## Arquitectura

El mismo diagrama tiene dos formatos:

- `architecture/relay-star-platform.svg` — composición horizontal para una
  pantalla amplia.
- `architecture/relay-star-mobile.svg` — composición vertical, texto grande y
  líneas simples para una pantalla angosta.

El README elige el formato según el ancho de pantalla. Los SVG escalan sin
perder nitidez, incluyen título y descripción accesibles y se pueden abrir en
su tamaño completo.

Ambos muestran la misma regla: los clientes y los engines hablan con el relay;
no hablan directamente entre sí. El formato mobile también aclara que la
estrella es el diseño futuro y que `v0.1` usa un relay por host.

Los dos diagramas actuales son vectores nativos. El formato vertical fue
revisado en un viewport de iPhone.

## Capturas Mobile

- `en/mobile/mobile-conversation.png` — una conversación.
- `en/mobile/mobile-sessions.png` — la lista de sesiones.
- `en/mobile/mobile-many-sessions.png` — varias sesiones trabajando.

La captura principal del README aparece sola y ocupa el ancho disponible. Las
vistas secundarias quedan dentro de bloques desplegables para que la lectura en
el iPhone siga siendo cómoda.

## Capturas Desktop

- `en/desktop/desktop-main.png` — lista de sesiones.
- `en/desktop/desktop-conversation.png` — una conversación.

Las referencias se obtuvieron de la app de desarrollo. En el README, Desktop
queda detrás de un bloque desplegable y cada captura se puede tocar para abrir
la resolución completa.

## Por qué son demostraciones

Los originales contenían títulos de sesiones, fragmentos de conversaciones,
rutas y un identificador real. Traducir sólo el idioma habría conservado datos
operativos privados.

Por eso las versiones públicas se regeneraron desde las referencias. Mantienen
la dirección visual y una disposición representativa, pero usan contenido
neutro en inglés. Son demostraciones del producto, no evidencia píxel por píxel
de una sesión real.

Durante la revisión de identidad pública, Imagegen integrado reemplazó sólo las
etiquetas visibles `Fermín Engine` por `Fermín` en las capturas que las
contenían. La captura de conversación Mobile conserva `FERMÍN` porque identifica
al participante.

## Dimensiones

- Mobile: aproximadamente 853 × 1844 píxeles.
- Desktop: 1587 × 991 píxeles.
- Arquitectura horizontal: SVG con proporción 1600 × 900.
- Arquitectura mobile: SVG con proporción 720 × 1240.

Antes de publicar se revisaron credenciales, endpoints, rutas personales,
identificadores de sesión y metadata.
