# Cliente Mobile de Fermín

Es el cliente nativo SwiftUI para iOS. Permite mandar una intención desde el
iPhone y dejar que la central se ocupe del transporte. Se conecta únicamente al
relay; nunca necesita una conexión directa con la Mac host.

El proyecto y scheme de Xcode conservan el nombre interno anterior `KyCode` y
la app mantiene identificadores Fermín Code por compatibilidad. El nombre
público del producto es Fermín.

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

El chat principal usa la sesión de Codex en la Mac del engine. El iPhone expresa
la intención; el host ejecuta. Por eso no necesita una clave de OpenAI u otro
proveedor dentro del bundle de iOS.

Las funciones opcionales de voz, narración y compartir pueden leer
`Resources/App/Secrets.plist`. Para probar alguna:

1. Copiá `Secrets.example.plist` al nombre ignorado `Secrets.plist`.
2. Reemplazá sólo los placeholders que necesite esa función.
3. Nunca confirmes el archivo resultante.

Una app iOS no puede esconder de forma segura un secreto compartido de larga
duración. No distribuyas credenciales de proveedores en una build pública;
colocá ese intercambio detrás de un backend controlado por vos.
