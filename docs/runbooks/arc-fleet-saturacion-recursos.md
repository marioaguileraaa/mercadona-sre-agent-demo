# Runbook: saturación de recursos en la flota Azure Arc (ArcBox FleetOps)

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

Este runbook es el destino de `customProperties.runbook` de las reglas
`alert-arcbox-fleet-cpu-saturation` y `alert-arcbox-fleet-memory-pressure`.

## Frontera de seguridad

Este runbook opera únicamente sobre:

- suscripción `5305e853-a63b-4b82-9a3f-6fde18c1a798`;
- tenant `9b1d3cd8-5db7-4564-905d-4d2eba7b66d5`;
- `rg-arcbox-itpro-weu-002`;
- inyección de presión: **solo** `ArcBox-Win2K22` y `ArcBox-Win2K25`;
- observación: las cinco máquinas Arc del grupo;
- `law-arcbox-demo-001`;
- agente `sre-agent-mercadona-v1` en `rg-mercadona-sre-agent-v1`, en modo `Review`/`Low`.

`ArcBox-SQL`, `Arcbox-Ubuntu-01`, `Arcbox-Ubuntu-02`, la VM anfitriona `ArcBox-Client` y cualquier
recurso Jumpstart están explícitamente fuera de la lista blanca de presión y los scripts los
rechazan.

Los eventos 5101/5102 de origen `Mercadona.FleetOps` son sintéticos. Los roles `adfs`,
`domain-controller`, `identity-sql` y `linux-edge` son etiquetas de presentación: estas máquinas no
ejecutan AD FS ni AD DS y sus métricas no describen ninguna operación real.

## Dependencia diaria de ArcBox

Las cinco máquinas Arc son invitados Hyper-V anidados sobre la VM `ArcBox-Client`. Antes de cada
sesión:

1. confirmar que `ArcBox-Client` está encendida;
2. esperar a que las máquinas objetivo aparezcan `Connected`;
3. confirmar `AzureMonitorWindowsAgent` en `Succeeded`;
4. esperar `Heartbeat` e `InsightsMetrics` recientes antes de inyectar presión.

`la-start-arcbox-client` arranca la VM padre a las 08:00 (`Romance Standard Time`) y el schedule
DevTestLab `shutdown-computevm-ArcBox-Client` la autoapaga a las 18:00 UTC. **No iniciar el
escenario a menos de 30 minutos del corte**: la presión dura 14 minutos y la recuperación necesita
telemetría posterior. La ausencia nocturna de `Heartbeat` e `InsightsMetrics` no es una avería.

## Umbrales y por qué son estos

| Regla | Condición | Ventana | Frecuencia | Severidad |
|---|---|---|---|---|
| `alert-arcbox-fleet-cpu-saturation` | `>= 8` muestras `>= 85 %` de CPU | `PT15M` | `PT5M` | Sev2 |
| `alert-arcbox-fleet-memory-pressure` | `>= 8` muestras `>= 80 %` de memoria usada | `PT15M` | `PT5M` | Sev2 |

`InsightsMetrics` muestrea cada 60 segundos, así que 8 muestras equivalen a más de la mitad de la
ventana. Sobre la línea base real de 7 días, un backtest de 344 ventanas × 5 máquinas dio **0**
disparos para ambas condiciones. No modificar umbral, ventana ni número de muestras sin recalcular
esa línea base y sin actualizar este runbook y `docs/arquitectura-arc-fleet-observability.md`.

La memoria usada se **deriva**: `InsightsMetrics` publica `Memory/AvailableMB` y el total viene de la
etiqueta `vm.azm.ms/memorySizeMB`. No existe contador directo de memoria usada en este entorno.

No hay alerta de disco. El disco es visualización, no señal de guardia.

## Secuencia de configuración

Las dos primeras órdenes son de solo lectura/planificación:

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\deploy-arc-fleet-observability.ps1
.\scripts\configure-arc-fleet-sre-agent.ps1
```

Aplicar solo tras revisar el what-if y el plan:

```powershell
.\scripts\deploy-arc-fleet-observability.ps1 -Apply
.\scripts\configure-arc-fleet-sre-agent.ps1 -Apply
.\scripts\verify-arc-fleet-observability.ps1
```

`verify-arc-fleet-observability.ps1` es de solo lectura y debe terminar con `0 fail`. Los `warn` de
telemetría indican parque apagado, no error de despliegue.

## Inyección controlada de presión

```powershell
.\scripts\start-arc-fleet-pressure.ps1            # plan, no cambia nada
.\scripts\start-arc-fleet-pressure.ps1 -Apply     # ejecuta
```

Envolvente aplicada por el script y por el propio payload:

- perfil por defecto `Split`: `ArcBox-Win2K22` memoria, `ArcBox-Win2K25` CPU;
- memoria en trozos de 64 MiB, máximo duro 2048 MB, por defecto 1800 MB;
- suelo de **700 MB disponibles** comprobado antes de cada asignación y en cada tick del bucle;
- CPU con ciclo de trabajo, máximo 8 runspaces, proceso en prioridad `BelowNormal`;
- duración 300-900 s, por defecto 840 s, con fecha límite propia dentro del payload;
- `finally` que libera memoria, cierra runspaces, restaura prioridad y emite el evento `5102`;
- recursos Run Command con prefijo `perfops-`, sin persistencia de ningún tipo.

El script se niega a arrancar si queda algún `perfops-*` sin limpiar. Anotar el `CorrelationId` que
imprime: es la clave para la recuperación y para las consultas de correlación.

## Triaje cuando salta la alerta

1. **Identificar** máquina, rol de demo y regla disparada desde el nombre `ArcBox FleetOps ...`.
2. **Contextualizar** contra la línea base: comparar el valor observado con el p95 de 7 días de esa
   misma máquina (`kql/arc-fleet`, panel de p95 del libro). Un 90 % de CPU sobre un p95 de 9 % es
   anomalía; sobre un p95 de 57 % es carga conocida.
3. **Confirmar que es sostenido**: contar las muestras infractoras dentro de la ventana de 15
   minutos. Menos de 8 no es incidente.
4. **Descartar origen sintético**: buscar eventos `Mercadona.FleetOps` `5101`/`5102` en `Event`. Si
   hay un `5101` sin su `5102` en la ventana, la presión es de la demo y la acción correcta es
   ejecutar la recuperación, no investigar la aplicación.
5. **Comprobar salud de plataforma**: frescura de `Heartbeat` e `InsightsMetrics`, y estado de
   aprovisionamiento de las extensiones. Cualquier extensión fuera de `Succeeded` es un hallazgo por
   sí misma.
6. **Revisar cambios**: `ConfigurationChange` en las horas previas responde a "¿por qué ahora?".
7. **Comprobar margen de disco** antes de proponer cualquier cambio de configuración.
8. **Registrar la recomendación en `Review`**. El agente no aplica nada por su cuenta y este runbook
   no autoriza remediación automática.

## Recuperación

```powershell
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID>           # inventario, no borra
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID> -Apply    # limpia y verifica
```

La recuperación borra los recursos Run Command `perfops-*`, muestra la salida JSON del payload,
verifica que no queda ninguno y consulta los últimos 10 minutos para confirmar que CPU y memoria han
vuelto por debajo de los umbrales. Si sigue por encima, esperar un ciclo más de ingesta antes de
escalar: la telemetría llega con retardo.

Ambas reglas se autoresuelven a los 15 minutos sin muestras infractoras.

## Reversión

- **Presión**: borrar todos los `perfops-*` con el script de recuperación. La memoria y los
  runspaces se liberan solos al terminar el payload, incluso si el Run Command se cancela.
- **Alertas**: deshabilitar o borrar las dos `scheduledQueryRules` en `rg-arcbox-itpro-weu-002`.
- **Libro**: borrar `Microsoft.Insights/workbooks` con las etiquetas de propiedad del escenario.
- **Agente**: borrar los cinco objetos `arc-fleet-*`. No tocar los objetos `identity-infrastructure-*`
  ni `mercadona-cart-*`: pertenecen a otros escenarios.
- **RBAC**: las asignaciones son compartidas con el escenario de identidad. No revocarlas sin
  comprobar antes que el otro escenario ya no está en uso.

Nada de esto modifica el grafo de conocimiento ni el conector del agente: los scripts los exigen
como precondición y fallan si no existen, en lugar de crearlos o reescribirlos.

## Lo que nunca se hace en este runbook

- Elevar el agente a `Autonomous` o a acceso `High`.
- Conceder permisos de escritura a la identidad administrada.
- Inyectar presión fuera de la lista blanca de dos máquinas.
- Superar el techo de 2048 MB o cruzar el suelo de 700 MB disponibles.
- Crear tareas programadas, servicios, claves de persistencia o reinicios en los invitados.
- Presentar los eventos sintéticos como actividad real de federación o de directorio.
