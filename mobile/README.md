# Cliente Mobile de Fermín

[← Volver al README](../README.md)

Es la app de iPhone para trabajar con las sesiones de Codex de una Mac. Manda
órdenes al relay y recibe lo que ocurre en esas sesiones. No se conecta
directamente con la Mac host ni con el engine.

[![Fermín Mobile mostrando varias sesiones activas](../docs/images/en/mobile/mobile-many-sessions.png)](../docs/images/en/mobile/mobile-many-sessions.png)

<sub>La imagen se puede abrir en resolución completa.</sub>

El proyecto y scheme de Xcode conservan el nombre interno anterior `KyCode`.
Los bundle identifiers de esta edición pública no cambian con la presentación.

## Generar el proyecto

```bash
xcodegen generate
open KyCode.xcodeproj
```

Antes de firmar, definí tus propios valores en `project.yml` o Xcode:

- bundle identifiers;
- `FERMIN_CODE_APP_GROUP`;
- `FERMIN_CODE_PRIMARY_RELAY_URL`;
- `FERMIN_CODE_SECONDARY_RELAY_URL`; y
- equipo de desarrollo Apple.

El repositorio no contiene equipo de firma, certificado, provisioning profile
ni URL de producción. Usá HTTPS para relays remotos. El acceso de red local es
sólo para descubrimiento y pruebas en una red controlada.

## Las claves de proveedores son opcionales

El chat principal usa la sesión de Codex que ya vive en la Mac del engine.
Mobile sólo manda la orden; el host hace el trabajo. Para ese flujo no hace
falta guardar una clave de OpenAI ni de otro proveedor dentro de la app de iOS.

Las funciones opcionales de voz, narración y compartir pueden leer
`Resources/App/Secrets.plist`. Para probar alguna:

1. Copiá `Secrets.example.plist` al nombre ignorado `Secrets.plist`.
2. Reemplazá sólo los placeholders que necesite esa función.
3. Nunca confirmes el archivo resultante.

Una app iOS no puede esconder de forma segura un secreto compartido durante
mucho tiempo. No distribuyas credenciales de proveedores en una build pública;
colocá ese intercambio detrás de un backend controlado por vos.

[Conectar relay, engine y clientes paso a paso →](../docs/SELF_HOSTING.md)
