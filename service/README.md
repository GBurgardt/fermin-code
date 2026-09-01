# Service: la central y los hosts

[← Volver al README](../README.md)

Este crate contiene el camino durable entre los clientes y Codex. Compila tres
comandos:

- `fermin-relay`: es la central. Recibe órdenes, las guarda, emite eventos SSE
  y mantiene la conexión con el host.
- `fermin-engine`: vive en cada Mac host. Inicia y observa Codex App Server y lo
  conecta con la central.
- `ferminctl`: comprueba la instalación local de Codex sin exponer
  diagnósticos irrestrictos.

## Lo que soporta `v0.1`

Una instancia de `fermin-relay` admite una generación activa de
`fermin-engine`. La arquitectura objetivo conserva un relay central y engines
separados por host, pero el routing de varios hosts dentro de una única
instancia todavía no está implementado.

## Probar

```bash
cargo fmt --check
cargo test --locked
```

## Configurar

Partí de:

- `config/relay.example.toml`
- `config/engine.example.toml`

Los nombres de configuración local real están ignorados por Git.

Los campos secretos contienen **rutas absolutas a archivos de token**, nunca
los valores. El loader rechaza:

- rutas de token relativas;
- permisos demasiado amplios;
- listeners fuera de loopback;
- workspace roots relativos; y
- una URL engine→relay fuera de loopback sin TLS.

Relay y engine usan bases SQLite separadas en modo WAL. La central guarda su
historia y cada host conserva su estado local. Ese diseño corresponde al
despliegue actual de una persona; no es almacenamiento multi-tenant ni
horizontalmente escalable.

Seguí [Autoalojamiento](../docs/SELF_HOSTING.md) para ejecutar el conjunto.

Para entender por qué relay y engine son piezas distintas, leé
[Arquitectura](../docs/ARCHITECTURE.md).
