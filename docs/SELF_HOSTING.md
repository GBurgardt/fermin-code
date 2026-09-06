# Autoalojamiento

[← Documentación](README.md)

Esta guía empieza con relay, engine y Codex en la misma Mac. Primero comprobá
el camino local; después agregá acceso desde otros dispositivos.

Es una instalación experimental para una persona. No configura servicios al
arrancar macOS, dominios, firma Apple ni actualizaciones automáticas.

## 1. Revisar el acceso que vas a dar

Leé el [modelo de seguridad](SECURITY_MODEL.md) antes de generar credenciales.
El engine usa `approvalPolicy=never`: no esperes una aprobación interactiva
antes de cada acción. El sandbox efectivo depende de la configuración de Codex
en el host. `workspaceRoots` limita rutas aceptadas por Fermín, no todos los
efectos de las herramientas.

Usá una cuenta y un entorno acordes al acceso que quieras conceder. No cambies
el sandbox a acceso total para resolver a ciegas un problema de instalación.
Esta guía no modifica la configuración de Codex.

## 2. Comprobar herramientas y compilar

Necesitás macOS, Rust 1.92 o posterior, Xcode Command Line Tools y Codex CLI
compatible y autenticado. Para Mobile necesitás además Xcode completo y
XcodeGen.

Desde la raíz del repositorio:

```bash
command -v codex
codex --version
(cd service && cargo build --locked --release)
service/target/release/ferminctl doctor \
  --codex "$(command -v codex)"
```

`doctor` comprueba compatibilidad con App Server. No demuestra que tu cuenta,
permisos y herramientas puedan completar cualquier tarea. Si falla, resolvé
esa incompatibilidad antes de añadir el relay.

## 3. Preparar dos archivos y tres tokens

Desde la raíz del repositorio, este bloque crea un directorio nuevo y privado.
Se detiene si ya existe; no lo borres ni sobrescribas para repetir el paso.

```bash
(
  set -eu
  umask 077
  fermin_config_dir="$HOME/Library/Application Support/FerminCode"
  mkdir "$fermin_config_dir"
  mkdir "$fermin_config_dir/secrets" "$fermin_config_dir/state"
  for token_name in client-token engine-token local-api-token; do
    openssl rand -hex -out "$fermin_config_dir/secrets/$token_name" 32
  done
  cp service/config/relay.example.toml "$fermin_config_dir/relay.toml"
  cp service/config/engine.example.toml "$fermin_config_dir/engine.toml"
)
```

Los tokens quedan en archivos privados y no se imprimen. Si el bloque falla,
revisá lo que alcanzó a crear; no inicia procesos ni modifica Codex.

Abrí los dos TOML con un editor:

- Reemplazá `/Users/USERNAME` por la ruta absoluta de tu usuario.
- En `engine.toml`, poné el resultado de `command -v codex` en `codexPath`.
- Reemplazá `workspaceRoots` por el proyecto o los proyectos que vas a usar.
- Mantené configuración, tokens y estado fuera de esos workspaces.

TOML no expande `$HOME` ni `~`. Los archivos de ejemplo ya conectan relay y
engine por loopback, comparten la ruta del token de engine y separan las bases.
No pegues el contenido de un token en TOML: los campos contienen rutas.

Los puertos son 8840 y 8841. Si los cambiás, actualizá también `relay.url`
en el engine. Los límites de tamaño, heartbeat y reconexión usan los valores
predeterminados de [config.rs](../service/src/config.rs); no hace falta copiar
todos esos ajustes para empezar.

## 4. Iniciar relay y engine

Desde la raíz del repositorio, en una terminal:

```bash
service/target/release/fermin-relay \
  --config "$HOME/Library/Application Support/FerminCode/relay.toml"
```

En otra:

```bash
service/target/release/fermin-engine \
  --config "$HOME/Library/Application Support/FerminCode/engine.toml"
```

Comprobá el relay, usando tu puerto si lo cambiaste:

```bash
curl --fail http://127.0.0.1:8840/healthz
```

Relay disponible y engine listo son estados diferentes. Esperá a que el health
muestre el engine conectado y listo antes de probar una tarea. Si cerrás estas
terminales, no hay un supervisor instalado por esta guía que las reemplace.

## 5. Conectar Desktop

```bash
cd desktop
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

En Ajustes, guardá el token de cliente generado en
`$HOME/Library/Application Support/FerminCode/secrets/client-token`.
Usá un editor o un método privado para introducirlo en la app; no
lo pegues en comandos, URLs, logs o issues. Desktop lo almacena en Keychain.

El token `engine-token` es sólo para engine → relay. `local-api-token` protege
la API local del engine. No los intercambies con el token de cliente.

Para generar la app con Xcode, seguí [Desktop](../desktop/README.md).

## 6. Preparar acceso remoto y Mobile

El relay sigue escuchando en loopback. Para llegar desde otro dispositivo,
configurá un proxy o túnel autenticado con TLS. Una VPN sola no convierte un
listener ligado a `127.0.0.1` en un servicio alcanzable desde otra máquina:
necesitás también publicar ese acceso de forma controlada.

La capa de acceso debe conservar streaming SSE y los upgrades WebSocket de
`/v1/engine/connect`. No expongas el engine ni App Server. Usá HTTPS para los
clientes y WSS si engine y relay están en máquinas distintas.

Mobile se configura con tu endpoint y token de cliente. Seguí
[Mobile](../mobile/README.md) para XcodeGen, bundle identifiers y firma. En el
iPhone, `127.0.0.1` apunta al propio teléfono, no a la Mac.

El chat usa la autenticación de Codex en el host. Las funciones opcionales de
voz requieren su propia configuración. No distribuyas una app con credenciales
de proveedores incrustadas. El repositorio tampoco publica ni instala apps
por OTA para otros usuarios.

## Si querés otra topología

Podés colocar el relay en otra máquina disponible para recibir pedidos mientras
el host está desconectado. Cambiá las rutas locales de almacenamiento y la
conexión del engine al relay. Esta guía no automatiza ese despliegue.

Para dos hosts, la versión actual usa dos pares relay–engine y los perfiles
Primary y Secondary. No hay un relay que distribuya trabajo entre varios hosts.

## Qué verificar antes de confiarle trabajo

- El health distingue relay disponible y engine listo.
- Desktop puede crear una sesión en el proyecto elegido.
- Un pedido de prueba produce eventos y un resultado que podés comprobar.
- Cerrar y abrir el cliente recupera la conversación.
- El acceso remoto funciona también fuera de la red local.

Una confirmación de recepción no demuestra que se terminó una tarea. Revisá
los [estados de la API](API.md), la política de órdenes demoradas y cómo vas a
proteger o respaldar los datos. Las pruebas de CI no sustituyen esta comprobación
en tu propia instalación.

[← Arquitectura](ARCHITECTURE.md) · [Documentación](README.md) · [API →](API.md)
