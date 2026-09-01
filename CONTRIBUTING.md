# Cómo contribuir

[← Volver al README](README.md)

## Elegí la superficie correcta

- Abrí un issue antes de cambiar comportamiento o arquitectura.
- Un bug pequeño, una prueba o una corrección documental puede ir directo a un
  pull request.
- Reportá vulnerabilidades mediante [SECURITY.md](SECURITY.md), nunca en un
  issue público.

Conservá la frontera del producto:

- `service/` contiene durabilidad, relay/engine, transporte y el adaptador de
  Codex App Server.
- `desktop/` y `mobile/` son clientes del relay.
- Codex es el harness. No reconstruyas su runtime de modelos ni sus
  herramientas dentro del relay.
- Los clientes no deben conectarse directamente al engine.

## Estado actual y arquitectura objetivo

Fermín se describe como una estrella N×M: clientes alrededor de un relay
central y engines en las Macs. `v0.1` admite una generación activa de engine
por instancia de relay. Una propuesta de routing multi-host debe incluir
identidad, autorización, almacenamiento y fencing por host; no alcanza con
agregar un campo `hostId`.

## Documentación

La documentación usa un tono técnico, neutral y directo.

1. Definí el componente o la operación.
2. Indicá el comportamiento observable.
3. Documentá requisitos y condiciones.
4. Documentá límites y estados de falla.
5. Separá la implementación actual de la arquitectura objetivo.

Usá “relay durable”, “host” y “engine” cuando aporten precisión y definilos la
primera vez. Evitá anécdotas, slogans, metáforas, preguntas retóricas, lenguaje
promocional y afirmaciones sin una condición verificable.

### Escribí también para una pantalla angosta

- Comprobá el documento a 390 px de ancho.
- Evitá tablas y diagramas que obliguen a desplazarse de costado.
- Mostrá primero la conclusión; plegá material secundario cuando sea largo.
- Usá texto alternativo y enlazá cada imagen a su resolución completa.
- Si agregás un video, acompañalo con una explicación textual y una imagen de
  portada que funcione como enlace.

## No publiques datos privados

No confirmes:

- dominios reales ni endpoints de producción;
- tokens ni archivos `.env`;
- certificados, provisioning profiles o equipos de firma;
- rutas personales ni contenido de sesiones;
- estado SQLite o logs; ni
- proyectos de Xcode generados.

Usá fixtures neutros como `relay.example.com`, `/Users/example/projects` y
texto de demostración.

## Verificá el componente modificado

```bash
(cd service && cargo fmt --check && cargo test --locked)
(cd desktop && swift test)
(cd mobile && xcodegen generate)
```

Para cambios de Mobile, compilá o probá además un target de simulador sin firma.
Para UI, adjuntá evidencia anterior y posterior sin conversaciones reales.
Para documentación visual, adjuntá también una revisión desde un viewport de
iPhone.

## Escribí un pull request útil

Respondé cinco preguntas:

1. ¿Qué problema existe?
2. ¿Por qué este componente es responsable?
3. ¿Afecta compatibilidad o seguridad?
4. ¿Qué pruebas y verificaciones pasaron?
5. ¿Hace falta migración o rollback?

Mantené el diff enfocado. No incluyas archivos generados ajenos al cambio. Las
contribuciones usan la licencia MIT del repositorio.
