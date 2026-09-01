# Política de seguridad

[← Volver al README](README.md)

## Código soportado

El trabajo de seguridad se aplica a la rama `main` y al último release. Los
commits anteriores no se mantienen como versiones soportadas independientes.

## Enviar reportes en privado

Usá el [reporte privado de vulnerabilidades de GitHub](https://github.com/GBurgardt/fermin-code/security/advisories/new).

No publiques en un issue, discusión o pull request:

- detalles de un exploit;
- endpoints de producción;
- tokens o secretos sospechados;
- datos personales; ni
- conversaciones reales.

Incluí el componente y commit afectados, impacto, condiciones de reproducción y
una prueba de concepto segura cuando exista. Ocultá credenciales y contenido de
usuarios.

Este proyecto voluntario no tiene SLA de respuesta. El tratamiento del reporte
y cualquier advisory dependen del impacto verificado y de la mitigación
disponible.

## El despliegue es responsabilidad del operador

Esta versión es autoalojada y para una sola persona. El operador controla el
ingreso TLS, la seguridad de la Mac, sandbox y aprobaciones de Codex, workspaces
permitidos, credenciales, retención y actualizaciones. Leé el
[modelo de seguridad](docs/SECURITY_MODEL.md) antes de exponer un relay fuera de
loopback.
