# Runbook: operaciones de identidad sintética sobre Azure Arc

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Frontera de seguridad

Este runbook opera únicamente sobre:

- suscripción `5305e853-a63b-4b82-9a3f-6fde18c1a798`;
- tenant `9b1d3cd8-5db7-4564-905d-4d2eba7b66d5`;
- `rg-arcbox-itpro-weu-002`, `ArcBox-Win2K22` y `ArcBox-Win2K25`;
- `law-arcbox-demo-001`;
- agente `sre-agent-mercadona-v1` en `rg-mercadona-sre-agent-v1`.

Los eventos 4101/4102 son sintéticos. No ejecutar los scripts contra otros recursos ni interpretar sus mensajes como AD FS/DC real.

## Dependencia diaria de ArcBox

`ArcBox-Win2K22` y `ArcBox-Win2K25` son máquinas anidadas. Antes de cada sesión:

1. iniciar la VM padre `ArcBox-Client` siguiendo el procedimiento de Jumpstart;
2. esperar a que ambas máquinas aparezcan `Connected`;
3. confirmar `AzureMonitorWindowsAgent` en `Succeeded`;
4. esperar Heartbeat e `InsightsMetrics` recientes antes de generar eventos.

La automatización existente `la-start-arcbox-client` está habilitada y arranca diariamente la VM padre a las 08:00 (`Romance Standard Time`). Sus cinco ejecuciones auditadas más recientes terminaron correctamente. Los invitados usan Hyper-V `AutomaticStartAction=Start` y `AutomaticStopAction=ShutDown`. No crear otra automatización de arranque: verificar siempre el resultado real porque el horario no sustituye el preflight.

El schedule DevTestLab `shutdown-computevm-ArcBox-Client` autoapaga la VM padre diariamente a las 18:00 UTC. La alerta de frescura solo evalúa desde las 08:20 `Europe/Madrid` hasta ese corte UTC. KQL aplica DST automáticamente: el inicio corresponde a 07:20 UTC en CET y 06:20 UTC en CEST; el fin corresponde a 19:00 CET y 20:00 CEST. No interpretar la ausencia nocturna de Heartbeat/InsightsMetrics como avería.

No iniciar la demo si la VM padre, una máquina anidada, AMA o LAW no están sanos.

Antes del primer despliegue, la línea base esperada es Heartbeat e `InsightsMetrics` para los cinco invitados, Change Tracking en tres Windows y ninguna fila en `Event`, `SecurityEvent` o `Perf`. `Perf` debe seguir vacío: `MSVMI-ama-vmi-default-dcr` ya produce 174 000 filas/24 h en `InsightsMetrics`. La DCR dedicada añade solo eventos Application/System, y el preflight exige conservar exactamente una asociación VM Insights en cada host objetivo.

Como referencia de dos horas, Win2K22 mostró CPU 4,38 % de media/11,51 % p95, ~2,53 GB disponibles, ~1 ms de latencia de disco y 80,31 % libre; Win2K25 mostró 9,71 %/19,32 %, ~2,19 GB, ~1,1-1,3 ms y 58,73 %. Usar estos datos solo para contexto del informe. No convertirlos en umbrales ni alertas de CPU, memoria, disco o espacio sin un baseline más largo y change control.

## Secuencia de configuración

Las dos primeras órdenes son de solo lectura/planificación:

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\deploy-arc-identity.ps1
.\scripts\configure-arc-identity-sre-agent.ps1
```

Revisar el `what-if` y el plan de RBAC. Con aprobación:

```powershell
.\scripts\deploy-arc-identity.ps1 -Apply -Confirm
.\scripts\configure-arc-identity-sre-agent.ps1 -Apply -Confirm
.\scripts\verify-arc-identity.ps1
```

La verificación exige:

- AMA correcto en los dos hosts;
- una asociación dedicada por host y ninguna en otros hosts;
- preservación visible de otras asociaciones;
- Heartbeat e `InsightsMetrics` recientes;
- dos reglas habilitadas Sev2/auto-resolve con la acción existente;
- RBAC exacto, conector LAW, subagente, skill, filtro y tarea;
- agente todavía `Review/Low`.
- tarea laborable a las 07:30 UTC, equivalente a 08:30 CET o 09:30 CEST y siempre posterior a la gracia de arranque.

`ag-mercadona-sre-demo` está habilitado sin receptores de forma intencionada. La extensión reutiliza únicamente su ID, igual que el patrón de alerta existente, y no crea correo, SMS, webhook ni otro receptor. No notifica al SRE Agent: la plataforma de incidentes Azure Monitor del agente detecta la regla y el filtro `identity-infrastructure-sev2` la enruta al subagente de solo lectura.

## Generar el incidente acotado

```powershell
.\scripts\start-arc-identity-incident.ps1
```

El script:

1. valida contexto, dos máquinas, Windows, `Connected` y AMA;
2. ejecuta Azure Arc Run Command como LocalSystem;
3. crea o reutiliza la fuente `Mercadona.IdentityOps` en Application;
4. escribe exactamente 12 eventos Warning por host, ID 4101;
5. incluye JSON con `demoSynthetic=true` y un `correlationId`;
6. consulta LAW por los dos `_ResourceId` permitidos antes de cada escritura y combina su recuento persistente con el log Application local mediante el máximo, evitando duplicados aunque el log local haya rotado;
7. limita el parámetro a 8-20 eventos por host;
8. elimina cada recurso Run Command temporal;
9. exige finalmente 12 eventos por cada host permitido, 24 eventos y dos máquinas en total.

Guardar el `correlationId` mostrado. No se producen logons, tokens, usuarios ni fallos de credenciales reales.

## Observar

Consultas seguras:

- [`synthetic-token-failure-burst.kql`](../../kql/arc-identity/synthetic-token-failure-burst.kql);
- [`performance-correlation.kql`](../../kql/arc-identity/performance-correlation.kql);
- [`fleet-heartbeat.kql`](../../kql/arc-identity/fleet-heartbeat.kql);
- [`data-freshness.kql`](../../kql/arc-identity/data-freshness.kql).

Resultado esperado:

- 24 eventos 4101 para la ejecución por defecto;
- alerta `alert-arcbox-identity-token-failure-burst` Sev2;
- referencia de acción a `ag-mercadona-sre-demo`;
- ningún aviso externo, porque el action group conserva cero receptores;
- investigación por `identity-infrastructure-analyzer`;
- explicación explícita de que Arc/AMA/LAW son reales y la fuente de identidad es sintética;
- ninguna acción de escritura sin revisión humana.

No proyectar `RenderedDescription`, nombres de usuario ni mensajes de eventos en el informe.

## Recuperar y verificar

```powershell
.\scripts\recover-arc-identity-incident.ps1 `
  -CorrelationId 'SYNTH-ID-REEMPLAZAR'
```

El script exige al menos un 4101 autoritativo en LAW para cada `_ResourceId`, combina los recuentos LAW/local mediante el máximo, emite como máximo un 4102 por host, elimina Run Command y espera exactamente dos recuperaciones en LAW. Los 4102 son marcadores auditables e idempotentes; no intervienen en la condición KQL de la alerta. Si el log Application local rotó pero LAW conserva el incidente, la recuperación sigue siendo válida; repetirla con el mismo ID no añade otra recuperación.

La regla se auto-resuelve cuando la ventana móvil de cinco minutos deja de contener eventos 4101, con independencia del momento en que se emitan los 4102. Si no se resuelve:

1. confirmar que no existen eventos 4101 nuevos con el mismo ID;
2. revisar estado de la regla y latencia de Azure Monitor;
3. no modificar umbral, DCR, acción ni modo del agente para acelerar la demo.

## Criterios de éxito

1. Las asociaciones existentes siguen presentes.
2. La DCR dedicada aparece solo en los dos Windows objetivo.
3. Heartbeat e `InsightsMetrics` tienen menos de 15 minutos.
4. La ráfaga es exactamente la acotada y contiene `demoSynthetic=true`.
5. El informe no afirma que los hosts ejecuten AD FS/DC.
6. El filtro y la tarea permanecen Review; el agente permanece Review/Low.
7. La recuperación produce un único 4102 por host y la alerta se resuelve al salir los 4101 de su ventana móvil.
8. No queda ningún Run Command `identityops-*`.

## Fallos y respuesta segura

| Síntoma | Respuesta |
|---|---|
| Guarda de tenant/suscripción/RG falla | detener; corregir el contexto, nunca eludir la guarda |
| VM padre apagada o Arc `Disconnected` | iniciar ArcBox según Jumpstart y esperar |
| AMA no está `Succeeded` | investigar extensión existente; no reinstalarla desde estos scripts |
| DCR/asociación del mismo nombre no pertenece a la demo | detener; no sobrescribir |
| LAW no recibe InsightsMetrics | revisar la asociación existente `MSVMI-ama-vmi-default-dcr` y AMA; no añadir contadores duplicados |
| La ráfaga ya supera el límite | detener y usar un correlation ID nuevo solo tras revisar |
| El agente sugiere remediación de identidad | rechazar; este POC solo investiga y recomienda |
| Evidencia sin `demoSynthetic=true` sugiere ataque real | detener demo y escalar a SOC/Microsoft Sentinel |

## Rollback controlado

Solo con aprobación del propietario y después de exportar/verificar el estado:

1. deshabilitar/retirar la tarea, filtro, skill, subagente y conector dedicados;
2. retirar exclusivamente las tres asignaciones RBAC añadidas al UAMI por ID exacto;
3. retirar las dos alertas dedicadas;
4. retirar `assoc-arcbox-identity-ops` solo en los dos hosts;
5. retirar `dcr-arcbox-identity-ops`;
6. quitar el RG ArcBox de `managedResources` preservando todos los demás.

No eliminar `rg-arcbox-itpro-weu-002`, máquinas, `AzureMonitorWindowsAgent`, `law-arcbox-demo-001`, VM Insights, otras DCR/asociaciones, la acción existente ni recursos retail. La fuente local `Mercadona.IdentityOps` y sus eventos seguros pueden expirar con la retención normal de Application; no se manipula el log para borrarlos.

## Costes

Los drivers incrementales son los eventos System/Application filtrados, evaluaciones de dos alertas y unidades/consultas de Azure SRE Agent. Los datos de rendimiento ya existen en `InsightsMetrics`; no duplicarlos en `Perf`. Monitorizar volumen tras el primer día y ajustar XPath con change control; no ampliar Security en este workspace.
