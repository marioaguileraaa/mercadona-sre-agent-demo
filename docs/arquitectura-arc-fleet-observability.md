# Arquitectura: observabilidad de flota Azure Arc (ArcBox FleetOps)

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Para qué sirve este escenario

El cliente tiene servidores AD FS y controladores de dominio on-premises conectados a Azure con
Azure Arc. Lo que pide es **monitorización y visualización de todo el parque**, y ver cómo Azure SRE
Agent detecta un problema real de recursos y propone recomendaciones.

Este escenario es **aditivo**: no toca el escenario minorista de memoria del carrito ni el escenario
de identidad Arc ya existente. Reutiliza el mismo workspace, el mismo grupo de acciones, la misma
identidad administrada y el mismo agente `sre-agent-mercadona-v1` en modo `Review`/`Low`.

## Alcance exacto

| Elemento | Valor |
|---|---|
| Suscripción | `5305e853-a63b-4b82-9a3f-6fde18c1a798` |
| Tenant | `9b1d3cd8-5db7-4564-905d-4d2eba7b66d5` |
| Grupo de recursos Arc | `rg-arcbox-itpro-weu-002` (westeurope) |
| Workspace | `law-arcbox-demo-001`, retención 30 días |
| Grupo de acciones | `ag-mercadona-sre-demo` en `rg-mercadona-sre-agent-v1` |
| Agente | `sre-agent-mercadona-v1`, `Review` / `Low` |

## Parque real utilizado

Las cinco máquinas son máquinas Arc reales, `Connected`, con Azure Monitor Agent en `Succeeded`,
VM Insights, Change Tracking, Defender y Update Manager. Son invitados Hyper-V anidados sobre la VM
`ArcBox-Client`, que arranca sobre las 08:00 `Europe/Madrid` y se autoapaga a las 18:00 UTC.

| Máquina Arc | Rol de demo | Host ficticio | Sitio | vCPU | Memoria |
|---|---|---|---|---|---|
| `ArcBox-Win2K22` | `adfs` | `adfs-01` | `site-a` | 2 | 4094,9 MB |
| `ArcBox-Win2K25` | `domain-controller` | `dc-01` | `site-a` | 2 | 4094,9 MB |
| `ArcBox-SQL` | `identity-sql` | `sql-01` | `site-b` | 2 | 6142,9 MB |
| `Arcbox-Ubuntu-01` | `linux-edge` | `edge-01` | `site-b` | 2 | 3914 MB |
| `Arcbox-Ubuntu-02` | `linux-edge` | `edge-02` | `site-b` | 2 | 3914 MB |

**La columna de rol es solo una etiqueta de presentación.** Estas máquinas no ejecutan AD FS ni
AD DS. El mapa vive en `Get-ArcFleetRoleMap` y en un `datatable` dentro de las consultas KQL; no se
aplica como etiqueta de recurso ni modifica ningún recurso en Azure.

## Señales

- **Rendimiento**: `InsightsMetrics`, producido por la regla preexistente `MSVMI-ama-vmi-default-dcr`
  con muestreo de **60 segundos**. No se crea ninguna DCR nueva.
  - CPU: `Namespace == "Processor"`, `Name == "UtilizationPercentage"`.
  - Memoria: `Namespace == "Memory"`, `Name == "AvailableMB"`. El porcentaje usado se **deriva**
    con la etiqueta `vm.azm.ms/memorySizeMB`; no existe contador directo de memoria usada.
  - Disco: `Namespace == "LogicalDisk"` con la etiqueta `vm.azm.ms/mountId`. Los pseudo-montajes de
    Linux bajo `/snap/`, `/sys/` y `/run/` se excluyen siempre: son squashfs de solo lectura que
    reportan permanentemente 0 % libre.
- **Conectividad**: `Heartbeat` y estado `status` de la máquina Arc.
- **Postura del agente**: extensiones de `Microsoft.HybridCompute/machines/extensions` vía Azure
  Resource Graph.
- **Cambios**: `ConfigurationChange` y `ConfigurationData` (solo Windows en este entorno).
- **Marcador sintético**: eventos `Application` de origen `Mercadona.FleetOps`, IDs `5101` (inicio) y
  `5102` (fin), con `demoSynthetic=true`. Se ingieren con la DCR de eventos ya existente
  `dcr-arcbox-identity-ops`, sin cambios.

Las tablas `Perf` y `SecurityEvent` están vacías **por diseño**. Un resultado vacío ahí es correcto.

## Línea base real de 7 días

Medida sobre el entorno real antes de definir los umbrales:

| Máquina | CPU media / p95 / p99 / máx | Memoria usada media / p95 / p99 / máx |
|---|---|---|
| `ArcBox-Win2K22` | 3,8 / 9,0 / 22,5 / 49,2 | 41,1 / 46,5 / 47,9 / 52,5 |
| `ArcBox-Win2K25` | 9,6 / 16,6 / 57,1 / 99,3 | 53,1 / 60,5 / 64,3 / 81,1 |
| `ArcBox-SQL` | 5,2 / 11,3 / 25,5 / 65,2 | 55,3 / 59,6 / 61,3 / 65,3 |
| `Arcbox-Ubuntu-01` | 1,0 / 1,5 / 4,1 / 40,5 | 18,2 / 19,3 / 19,8 / 25,6 |
| `Arcbox-Ubuntu-02` | 1,0 / 1,5 / 4,1 / 40,5 | 18,2 / 19,5 / 19,9 / 25,6 |

Backtest sobre 344 ventanas de 15 minutos × 5 máquinas:

- `>= 8 muestras >= 85 %` de CPU: **0** disparos históricos.
- `>= 8 muestras >= 80 %` de memoria usada: **0** disparos históricos.

Es decir: los umbrales elegidos **no pueden** dar falso positivo sobre el comportamiento observado.
Un disparo significa presión sostenida realmente anómala, no un pico normal.

## Reglas de alerta

Ambas son `Microsoft.Insights/scheduledQueryRules` en `rg-arcbox-itpro-weu-002`.

| Propiedad | `alert-arcbox-fleet-cpu-saturation` | `alert-arcbox-fleet-memory-pressure` |
|---|---|---|
| Severidad | Sev2 | Sev2 |
| Condición | `>= 8` muestras `>= 85 %` CPU | `>= 8` muestras `>= 80 %` memoria usada |
| Ventana | `PT15M` | `PT15M` |
| Frecuencia | `PT5M` | `PT5M` |
| Autoresolución | sí, `PT15M` | sí, `PT15M` |
| Grupo de acciones | `ag-mercadona-sre-demo` | `ag-mercadona-sre-demo` |
| Prefijo de `displayName` | `ArcBox FleetOps` | `ArcBox FleetOps` |

El prefijo `ArcBox FleetOps` es el contrato con el filtro de incidentes del agente y lo distingue de
`ArcBox IdentityOps` y del escenario minorista. No se crea alerta de disco: el disco es solo
visualización.

## Libro de Azure Monitor

`ArcBox FleetOps - Azure Arc fleet observability`, desplegado como `Microsoft.Insights/workbooks`
compartido en `rg-arcbox-itpro-weu-002`. 15 paneles de consulta validados contra el entorno real:

1. Conectividad y versión del agente por máquina.
2. Inventario de flota con rol de demo, sistema operativo y sitio.
3. Estado de aprovisionamiento de las 29 extensiones, agrupadas por capacidad.
4. Cobertura de capacidades (AMA, Defender, Update Manager, Change Tracking).
5. Frescura de `Heartbeat` e `InsightsMetrics` por máquina.
6. Serie temporal de CPU por máquina.
7. Serie temporal de memoria usada por máquina.
8. Instantánea de 15 minutos equivalente a lo que evalúan las alertas.
9. Resumen de rendimiento (media, p95, máximo) por máquina.
10. Capacidad de disco por punto de montaje real.
11. p95 de 7 días frente a la línea base documentada.
12. Change Tracking agregado.
13. Eventos sintéticos de identidad y de flota.
14. Reglas de alerta configuradas.
15. Alertas disparadas.

El libro incorpora el aviso de demo ficticia en cabecera y pie, y la tabla del mapa de roles.

## Configuración del Azure SRE Agent

Todo aditivo, todo de solo lectura, todo en `Review`:

| Objeto | Nombre | Detalle |
|---|---|---|
| Skill | `arc-fleet-observability` | Incluye los 10 ficheros KQL revisados de `kql/arc-fleet` |
| Subagente | `arc-fleet-analyzer` | Herramientas de solo lectura, sin `handoffs` |
| Filtro de incidentes | `arc-fleet-performance-sev2` | Sev2 + `titleContains: ArcBox FleetOps`, `Review`, investigación profunda |
| Tarea programada | `arc-fleet-weekday-health-report` | Cron `45 7 * * 1-5` |
| Tarea programada | `arc-fleet-weekly-capacity-report` | Cron `0 8 * * 1` |

Herramientas concedidas: `RunAzCliReadCommands`, `QueryLogAnalyticsByWorkspaceId`, `SearchMemory`,
`GetAzCliHelp`, `FindConnectedGitHubRepo`. Ninguna herramienta de escritura, remediación, reinicio o
escalado.

Los scripts rechazan la ejecución si el agente no está ya en `Review`/`Low`, si la identidad de
acción no es la UAMI esperada, o si un objeto con el mismo nombre existe sin las etiquetas de
propiedad `synthetic-identity` + `azure-arc` + `arc-fleet`.

RBAC de la identidad `id-mercadona-sre-v1` (ya concedido, idempotente): `Reader` y
`Monitoring Reader` sobre `rg-arcbox-itpro-weu-002`, y `Log Analytics Reader` sobre
`law-arcbox-demo-001`. Nada más.

## Inyección de presión controlada

Se usa Arc Run Command con ejecución asíncrona. Envolvente de seguridad:

- Solo `ArcBox-Win2K22` y `ArcBox-Win2K25`. `ArcBox-SQL`, los Ubuntu, la VM anfitriona `ArcBox-Client`
  y cualquier otro recurso Jumpstart están fuera de la lista blanca y se rechazan.
- Perfil por defecto `Split`: `ArcBox-Win2K22` recibe presión de **memoria** y `ArcBox-Win2K25`
  presión de **CPU**. Dispara las dos reglas Sev2 a la vez y reparte la carga sobre el host
  compartido de 8 vCPU.
- Memoria en trozos de 64 MiB, tocados y anclados, máximo duro 2048 MB, por defecto 1800 MB, con un
  **suelo de 700 MB disponibles** que se comprueba antes de cada asignación y en cada tick del bucle
  de mantenimiento. Con ese suelo ambos hosts se estabilizan alrededor del 82-83 % de memoria usada.
- CPU mediante procesos trabajadores efímeros con ciclo de trabajo sobre una ventana de 1000 ms,
  prioridad `BelowNormal` y máximo 8 trabajadores. Azure Arc Run Command ejecuta el payload dentro
  de un *job object* de Windows con la tasa de CPU limitada, por lo que los hilos creados dentro del
  propio proceso nunca pueden elevar la CPU de la máquina; los trabajadores se crean por tanto con
  `Win32_Process`, fuera de ese *job object*. Cada trabajador calcula su propia fecha límite a partir
  de la ventana aprobada restante, de modo que no puede sobrevivir a la ventana ni aunque el proceso
  padre se termine bruscamente.
- Duración validada entre 300 y 900 segundos, por defecto **840 s (14 min)**. El payload se
  autotermina por su propia fecha límite.
- El bloque `finally` libera siempre toda la memoria, detiene todos los procesos trabajadores,
  restaura la prioridad y emite el evento `5102`.
- Los recursos Run Command se llaman `perfops-*` y los borra el script de recuperación.
- Sin tarea programada, sin servicio, sin cambio de registro más allá del origen de eventos, sin
  reinicio, sin descarga de red, sin persistencia.

## Ficheros

```text
infra/arc-fleet-observability.bicep            orquestador a nivel de suscripción
infra/arc-fleet-observability.parameters.json  parámetros del entorno real
infra/core/arc-fleet-monitoring.bicep          libro + 2 reglas Sev2
infra/workbooks/arc-fleet-observability.workbook.json
kql/arc-fleet/*.kql                            10 consultas agregadas revisadas
scripts/ArcFleet.Common.ps1                    contratos, límites y generador de payload
scripts/deploy-arc-fleet-observability.ps1     what-if por defecto, -Apply protegido
scripts/configure-arc-fleet-sre-agent.ps1      skill, subagente, filtro y 2 informes
scripts/start-arc-fleet-pressure.ps1           presión acotada
scripts/recover-arc-fleet-pressure.ps1         limpieza y verificación de recuperación
scripts/verify-arc-fleet-observability.ps1     verificación de solo lectura extremo a extremo
scripts/test-arc-fleet-contract.ps1            contrato offline, sin tocar Azure
docs/guia-demo-arc-fleet-60min.md              guion de 60 minutos
docs/runbooks/arc-fleet-saturacion-recursos.md runbook de saturación
```

## Lo que este escenario no hace

- No crea DCR nuevas ni duplica contadores de rendimiento.
- No modifica la configuración del grafo de conocimiento ni el conector del agente: exige que ya
  existan y falla con un mensaje claro si no es así.
- No amplía el agente a `Autonomous` ni a acceso `High`.
- No remedia nada de forma autónoma. Toda recomendación queda en `Review`.
- No inventa datos de AD FS ni de AD DS, ni presenta los eventos sintéticos como actividad real de
  federación o de directorio.
