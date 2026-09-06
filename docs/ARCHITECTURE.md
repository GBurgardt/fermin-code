# Arquitectura

[← Documentación](README.md)

Fermín permite dirigir sesiones de Codex en una Mac propia desde otros
dispositivos. Codex sigue siendo el agente; Fermín agrega clientes, organización
y persistencia alrededor de las órdenes.

## Cuatro responsabilidades

```text
Clientes: iPhone / Mac
          ↓
Relay: recepción y eventos
          ↓
Engine: conexión con el host
          ↓
Codex App Server: ejecución
```

- Los clientes envían operaciones por REST, reciben eventos SSE y guardan
  tokens en Keychain. No ejecutan Codex ni se conectan directamente al engine.
- El relay autentica, guarda órdenes y eventos en SQLite y los entrega al
  engine. Puede seguir recibiendo mientras éste no esté conectado.
- El engine guarda su estado local, inicia App Server por stdio y adapta las
  operaciones a threads y turns. Mantiene un carril de comandos por sesión.
- Codex razona y usa las herramientas disponibles en el host. Los scripts,
  simuladores y servicios particulares del operador no forman parte de Fermín.

Cada relay admite una generación activa de engine. Primary y Secondary son
perfiles para dos pares independientes, no routing multi-host en una central.
No hay una arquitectura futura comprometida.

## Por qué relay y engine son procesos separados

Recibir una orden no debería depender de que Codex esté listo en ese instante.
El relay conserva el pedido; el engine necesita el entorno del host para
entregarlo. Son responsabilidades distintas.

Podés ejecutarlos en la misma Mac. Es la instalación más simple, pero si esa
Mac se apaga tampoco puede recibir pedidos. Separar el relay permite seguir
recibiendo mientras el host está desconectado; no permite ejecutar sin él.

Si App Server termina, el engine deja de estar listo. Esta distribución no
instala un supervisor que lo reinicie automáticamente.

## El recorrido de una orden

1. El cliente genera una clave de idempotencia y envía la operación.
2. El relay la guarda antes de responder `accepted`.
3. El engine la recibe y guarda antes de responder `engineDurable`.
4. Registra `sentToChild` antes de intentar la operación externa.
5. Cuando termina el manejo de esa operación, registra `completed` o un error.
6. Los clientes reciben eventos y reconstruyen su vista.

En un envío de mensaje, `completed` puede indicar que empezó un turno. No
certifica que el turno, la tarea o un despliegue hayan terminado. Consultá
[los estados exactos](API.md#semántica-de-accepted).

## Lo que no conviene quitar al simplificar

- Persistencia antes de confirmar recepción.
- Idempotencia: la misma clave reconoce una orden existente.
- Replay: cada cliente retoma eventos desde su propio cursor; si faltan,
  necesita un snapshot.
- Lease y fencing: una conexión vieja no conserva autoridad después de que
  entra una generación nueva.
- El estado `unknown`: representa un intento cuyo resultado no se pudo
  confirmar.

Una caída entre una acción externa y su registro no se puede deshacer con una
transacción de SQLite. En la recuperación, las órdenes que quedaron en
`sentToChild` pasan a `unknown`; no se reenvían automáticamente. El operador
debe revisar la sesión y sus efectos antes de repetirlas.

Tampoco una clave de idempotencia hace idempotente un despliegue o un comando
de shell. No hay garantía de ejecución exactamente una vez.

## Qué aporta cada capa a la continuidad

Si se desconecta un cliente, una orden ya aceptada permanece en el relay.
Cuando vuelve, consume eventos desde su cursor.

Si se desconecta el engine, el relay disponible conserva trabajo pendiente
para su regreso. No hay un vencimiento general de órdenes demoradas:
quien las envía debe considerar que pueden ejecutarse después.

Si falla el almacenamiento, esta arquitectura no sustituye respaldos ni
recupera por sí sola los datos perdidos.

Los carriles por sesión ordenan comandos, pero no aíslan archivos, simuladores
o servidores compartidos entre sesiones.

## Funciones alrededor de Codex

El mejorador opcional prepara una transformación y la somete a otra revisión
de fidelidad. Conserva el original y falla sin enviar la transformación si la
revisión la rechaza. Son llamadas adicionales a un modelo, no una prueba
formal de equivalencia. El explicador es otra función auxiliar.

Los módulos `features.rs` y `observer.rs` implementan esas funciones.
No reemplazan el runtime de herramientas de Codex.

El adaptador principal usa `approvalPolicy=never` y no ofrece aprobaciones
interactivas. `workspaceRoots` valida rutas de Fermín; no es un sandbox del
sistema operativo. [Modelo de seguridad](SECURITY_MODEL.md).

## Dónde leer el código

- [API](../service/src/api.rs): contrato usado por ambos clientes.
- [Relay](../service/src/relay.rs) y [bridge](../service/src/bridge.rs): transporte y entrega.
- [Engine](../service/src/engine.rs): adaptación a App Server.
- [Store](../service/src/store.rs): persistencia.
- [Protocol](../service/src/protocol.rs): órdenes, estados y eventos.

Los alias HTTP históricos siguen por compatibilidad. Una instalación nueva
puede usar la API sin prefijo.

[Autoalojamiento →](SELF_HOSTING.md)
