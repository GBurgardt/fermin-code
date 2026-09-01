# Service: relay y engine

[← Volver al README](../README.md)

Este crate contiene las piezas que corren fuera de los clientes. Compila tres
comandos:

- `fermin-relay`: recibe órdenes, las guarda, emite eventos SSE y mantiene la
  conexión con la Mac host.
- `fermin-engine`: vive junto a Codex en cada Mac host. Inicia Codex App Server,
  observa su estado y lo conecta con el relay.
- `ferminctl`: comprueba la instalación local de Codex sin exponer
  diagnósticos irrestrictos.

## Lo que soporta `v0.1`

Cada instancia de `fermin-relay` trabaja con una generación activa de
`fermin-engine`. El diseño futuro mantiene un relay central y un engine por
host, pero un solo relay todavía no puede elegir entre varios hosts.

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

Relay y engine usan bases SQLite separadas en modo WAL. El relay guarda la
historia compartida y cada host conserva su estado local. Está pensado para la
instalación actual de una persona; no es almacenamiento multi-tenant ni está
preparado para escalar horizontalmente.

Seguí [Autoalojamiento](../docs/SELF_HOSTING.md) para ejecutar el conjunto.

Para entender por qué relay y engine son piezas distintas, leé
[Arquitectura](../docs/ARCHITECTURE.md).
