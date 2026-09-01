# Autoalojamiento

[← Documentación](README.md)

Esta guía monta la forma más corta de Fermín: una Mac funciona como central y
como host al mismo tiempo. Relay, engine y Codex viven juntos.

No instala servicios de fondo, no crea un dominio público y no configura firma
de Apple.

## Antes de empezar

Necesitás una Mac con Rust 1.92 o posterior, Xcode Command Line Tools y un Codex
CLI compatible ya autenticado. Xcode completo y XcodeGen sólo son necesarios
si también vas a generar Mobile.

La guía tiene ocho pasos. Primero deja funcionando el camino local. El acceso
remoto aparece al final, cuando ya podés separar un problema de Fermín de un
problema de red.

## Lo que vas a montar

```text
Mobile / Desktop ──▶ relay local ──▶ engine local ──▶ Codex App Server
```

Al terminar, un cliente podrá mandar una orden al relay local. El relay la
guardará y el engine de esa misma Mac la entregará a Codex.

En `v0.1`, una instancia de relay acepta una generación activa de engine. Para
operar dos Macs hoy, desplegá un par relay–engine por Mac y configurá los dos
endpoints en Primary y Secondary. Una única central que derive hacia muchos
hosts todavía pertenece a la arquitectura objetivo.

## 1. Comprobar la Mac host

Primero comprobá que Codex funciona en la Mac donde va a correr el engine.

```bash
command -v codex
codex --version
```

Compilá el servicio y comprobá su conexión local con Codex:

```bash
(cd service && cargo build --release)
(cd service && cargo run --bin ferminctl -- doctor --codex "$(command -v codex)")
```

No sigas hasta que `ferminctl doctor` termine correctamente. Este paso confirma
que la Mac host puede hablar con Codex antes de agregar el relay.

## 2. Crear tres tokens

Creá un token distinto para cada frontera:

- clientes → relay;
- engine → relay; y
- API local del engine.

Este comando crea archivos privados desde el inicio:

```bash
umask 077
mkdir -p "$HOME/Library/Application Support/FerminCode/secrets"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/client-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/engine-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/local-api-token"
chmod 600 "$HOME/Library/Application Support/FerminCode/secrets/"*-token
```

Los archivos de configuración guardan rutas a tokens, no sus valores. No pegues
un token en TOML, logs, historial del shell ni Git.

## 3. Iniciar la central

Prepará `service/config/relay.toml`:

1. Copiá `service/config/relay.example.toml` al nombre anterior.
2. Reemplazá `USERNAME`.
3. Apuntá los tokens de cliente y engine a los archivos del paso 2.

Después iniciá el proceso:

```bash
service/target/release/fermin-relay \
  --config service/config/relay.toml
```

El relay escucha solamente en loopback, en el puerto 8840. Comprobalo:

```bash
curl --fail http://127.0.0.1:8840/healthz
```

## 4. Iniciar el engine

Prepará `service/config/engine.toml` a partir de
`service/config/engine.example.toml`. Configurá:

- `codexPath` con la ruta absoluta devuelta por `command -v codex`;
- `workspaceRoots` sólo con directorios que Codex remoto pueda usar;
- `authTokenFile` con el token de la API local;
- `relay.tokenFile` con el token del engine; y
- `relay.url` como `ws://127.0.0.1:8840/v1/engine/connect` para este montaje
  en la misma Mac.

Iniciá el engine:

```bash
service/target/release/fermin-engine \
  --config service/config/engine.toml
```

Consultá `/healthz` otra vez. Debe mostrar un engine conectado y listo. La
central ya tiene un host capaz de continuar las órdenes.

## 5. Conectar Desktop

Ejecutá el cliente contra el relay local:

```bash
cd desktop
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

Abrí Ajustes y guardá el token de cliente. Para una build de Xcode, configurá
`FERMIN_CODE_PRIMARY_RELAY_URL` en `desktop/project.yml` o en los build
settings del target generado.

## 6. Conectar Mobile

Definí tus valores en `mobile/project.yml`:

- `FERMIN_CODE_PRIMARY_RELAY_URL`;
- `FERMIN_CODE_SECONDARY_RELAY_URL` si tenés un segundo par relay–engine; y
- `FERMIN_CODE_APP_GROUP` si usás la extensión de compartir.

Generá el proyecto:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

Elegí tu equipo de desarrollo y bundle identifiers en Xcode. El chat principal
usa la sesión de Codex de la Mac del engine; no necesita una clave del proveedor
de modelos dentro de iOS. `Secrets.example.plist` documenta sólo ajustes
opcionales de voz y compartir.

## 7. Acceder remotamente

Mantené el relay ligado a `127.0.0.1`. Colocá delante una de estas opciones:

- un túnel TLS saliente;
- una red privada WireGuard o Tailscale; o
- un reverse proxy configurado y protegido por vos.

El edge debe preservar streaming SSE y upgrades WebSocket para
`/v1/engine/connect`. Usá tu propio dominio, separá los tokens de cliente y
engine, y probá HTTPS y WSS.

No ligues el relay directamente a `0.0.0.0` como atajo. Este repositorio no
automatiza el ingreso público.

## 8. Entender qué ocurre si la Mac se apaga

Con relay y engine en la misma Mac, un apagado deja ambos fuera de línea. La
central no puede tomar custodia de órdenes nuevas durante ese intervalo.

Si necesitás aceptar órdenes mientras la Mac de trabajo está desconectada, el
relay debe vivir en otra máquina disponible. El host podrá volver después y
continuarlas. Esta guía no automatiza ese despliegue y `v0.1` sigue admitiendo
un engine por instancia.

## Comprobación final

Antes de llamar terminada a la instalación, verificá estas cuatro cosas:

- `/healthz` muestra relay y engine listos;
- Desktop puede crear o abrir una sesión;
- una orden aparece en Codex y devuelve eventos; y
- cerrar y volver a abrir el cliente recupera la historia.

La prueba local confirma el producto. El túnel o proxy confirma sólo el acceso
remoto.

---

[← Arquitectura](ARCHITECTURE.md) · [Documentación](README.md) ·
[Siguiente: API →](API.md)
