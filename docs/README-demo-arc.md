# README de ejecución: demo de Azure Arc + Azure SRE Agent

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

Este documento son **los pasos**. Qué ejecutar, en qué orden, cuánto tarda cada cosa y qué hacer si
algo se tuerce. El relato para el cliente está en la guía de 60 minutos; aquí solo está la mecánica.

| Documento | Para qué |
|---|---|
| **Este archivo** | Los pasos de ejecución. Lo que tienes abierto mientras presentas. |
| [`guia-demo-arc-fleet-60min.md`](guia-demo-arc-fleet-60min.md) | El guion narrativo tramo a tramo y las respuestas a preguntas. |
| [`arquitectura-arc-fleet-observability.md`](arquitectura-arc-fleet-observability.md) | Cómo está construido y por qué. Para la conversación técnica profunda. |
| [`runbooks/arc-fleet-saturacion-recursos.md`](runbooks/arc-fleet-saturacion-recursos.md) | Triaje del incidente y rollback. Para enseñar cómo se opera de verdad. |

---

## 0. Requisitos

- PowerShell 7 (`pwsh`) y Azure CLI con `az bicep` instalado.
- Sesión iniciada: `az login`, con acceso a la suscripción `5305e853-a63b-4b82-9a3f-6fde18c1a798`.
- Permisos de escritura sobre `rg-arcbox-itpro-weu-002` y `rg-mercadona-sre-agent-v1` **solo para la
  preparación**. Durante la demo no se escribe nada salvo los Run Command de presión.
- La consola abierta en la raíz del repositorio.

Todos los scripts llevan los valores de esta demo como valores por defecto: no hace falta pasar
ningún parámetro.

> **Regla que se aplica a todos los scripts:** sin `-Apply` solo planifican e imprimen lo que harían.
> Con `-Apply` ejecutan. En consolas no interactivas añade también `-Confirm:$false`.

---

## 1. Preparación, una sola vez (D-1)

Se hace el día anterior. Tarda unos 10 minutos y deja el entorno listo para siempre; no hay que
repetirlo antes de cada demo.

```powershell
cd <raíz del repositorio>
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
```

### 1.1 Validación local (offline, no toca Azure)

```powershell
pwsh -NoProfile -File .\scripts\test-arc-fleet-contract.ps1
az bicep build --file .\infra\arc-fleet-observability.bicep
az bicep lint  --file .\infra\arc-fleet-observability.bicep
```

Debe terminar con `Arc fleet contract test passed all 460 assertion(s).` y sin errores de Bicep.

### 1.2 Infraestructura: libro y las dos reglas Sev2

```powershell
# Plan (what-if, no cambia nada)
.\scripts\deploy-arc-fleet-observability.ps1

# Aplicar
.\scripts\deploy-arc-fleet-observability.ps1 -Apply
```

Crea el libro `ArcBox FleetOps - Azure Arc fleet observability` y las reglas
`alert-arcbox-fleet-cpu-saturation` y `alert-arcbox-fleet-memory-pressure`, ambas apuntando al grupo
de acciones `ag-mercadona-sre-demo` que ya existía. **No crea ninguna Data Collection Rule nueva**:
los datos vienen de `MSVMI-ama-vmi-default-dcr`, que ya estaba desplegada.

### 1.3 Configuración del Azure SRE Agent

```powershell
# Plan
.\scripts\configure-arc-fleet-sre-agent.ps1

# Aplicar
.\scripts\configure-arc-fleet-sre-agent.ps1 -Apply
```

Registra en `sre-agent-mercadona-v1`:

| Objeto | Nombre | Qué hace |
|---|---|---|
| Skill | `arc-fleet-observability` | Las 10 consultas KQL revisadas del repositorio. |
| Subagente | `arc-fleet-analyzer` | El analista que investiga la saturación. |
| Filtro de incidentes | `arc-fleet-performance-sev2` | Abre hilo automáticamente con las dos alertas Sev2. |
| Tarea programada | `arc-fleet-weekday-health-report` | Informe de salud, `45 7 * * 1-5`. |
| Tarea programada | `arc-fleet-weekly-capacity-report` | Informe de capacidad, `0 8 * * 1`. |

El agente se queda en **`Review` / `Low`**: propone, nunca ejecuta.

### 1.4 Verificación completa

```powershell
.\scripts\verify-arc-fleet-observability.ps1
```

Son 46 comprobaciones de solo lectura. **Debe terminar con `0 fail`.** Un `warn` de telemetría
significa que el parque ArcBox está apagado fuera de su ventana diaria; no es un problema.

---

## 2. El día de la demo, T-45 minutos

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\verify-arc-fleet-observability.ps1
```

Checklist:

- [ ] `verify` termina con **`0 fail`**.
- [ ] La VM anfitriona **`ArcBox-Client` está encendida**. Arranca sola a las 08:00 (Romance Standard
      Time) con la Logic App `la-start-arcbox-client` y **se autoapaga a las 18:00 UTC**.
- [ ] **La sesión termina al menos 30 minutos antes de las 18:00 UTC.** Si no, hay que adelantarla o
      reprogramar el apagado.
- [ ] Las cinco máquinas Arc en `Connected` y las 29 extensiones en `Succeeded` (lo dice `verify`).
- [ ] No queda ningún Run Command `perfops-*` de un ensayo anterior:

      ```powershell
      az resource list --resource-group rg-arcbox-itpro-weu-002 `
        --resource-type "Microsoft.HybridCompute/machines/runCommands" `
        --query "[?contains(name,'perfops')].name" -o tsv
      ```

      Si sale algo, límpialo con `.\scripts\recover-arc-fleet-pressure.ps1 -Apply -Confirm:$false`.
      El script de arranque se niega a empezar si queda alguno, así que esto no es opcional.
- [ ] Pestañas abiertas: libro, hoja de alertas, interfaz del SRE Agent (enlaces en la sección 6).
- [ ] Consola PowerShell abierta en la raíz del repositorio.

---

## 3. Ejecución cronometrada

Los tiempos son los **medidos en un ensayo real** (ver sección 7), no estimaciones.

| Minuto de sesión | Reloj relativo | Qué haces |
|---|---|---|
| 0 – 8 | | Contexto y arquitectura. **No lances nada todavía.** |
| **8** | **T+0** | **Lanzas la presión.** Apunta el `CorrelationId`. |
| 8 – 11 | T+0 → T+3 | Arc despacha el Run Command. Aún no se ve nada: es normal. |
| 11 – 19 | T+3 → T+11 | Recorrido del libro mientras la carga sube en directo. |
| **~19 – 20** | **T+11 → T+12** | **Se disparan las dos alertas Sev2.** |
| **~21** | **T+13** | **El SRE Agent abre los dos hilos de incidente.** |
| 22 – 24 | T+14 → T+15 | El payload se autotermina y libera todo. |
| 24 – 40 | | Investigación del agente, recomendaciones e informes programados. |
| ~35 – 38 | T+27 → T+30 | Las alertas se autoresuelven solas al pasar 15 min sin muestras. |
| 50 – 60 | | Recuperación, verificación final y preguntas. |

### Paso 3.1 — Lanzar la presión (minuto 8)

```powershell
# Plan: enseña la envolvente de seguridad sin ejecutar nada
.\scripts\start-arc-fleet-pressure.ps1

# Ejecutar
.\scripts\start-arc-fleet-pressure.ps1 -Apply
```

Perfil por defecto `Split`, 840 segundos:

- `ArcBox-Win2K22` → **presión de memoria** (1800 MB, techo 2048 MB, suelo 700 MB disponibles).
- `ArcBox-Win2K25` → **saturación de CPU** (2 workers, ciclo de trabajo 95 %).

Así se disparan las dos reglas y se ven **dos incidentes distintos** en el agente, que es mucho más
demostrativo que uno solo.

**Copia el `CorrelationId` que imprime.** Tiene la forma `fleetops-20260803T103946Z-6d12e17a` y lo
necesitas en el paso 3.3.

Variantes útiles:

```powershell
# Un minuto más de presión (900 s es el máximo permitido)
.\scripts\start-arc-fleet-pressure.ps1 -Apply -DurationSeconds 900

# Solo memoria, o solo CPU, en las dos máquinas
.\scripts\start-arc-fleet-pressure.ps1 -Apply -PressureProfile Memory
.\scripts\start-arc-fleet-pressure.ps1 -Apply -PressureProfile Cpu
```

### Paso 3.2 — Mientras sube (minutos 11-19)

No hay comandos que ejecutar. Se recorre el libro. Los paneles que interesan, por este orden:
conectividad, inventario por rol, salud de extensiones, cobertura de capacidades, frescura de
telemetría, series de CPU y memoria, **instantánea de 15 minutos** (aquí se ve el contador de
muestras infractoras acercándose a 8), p95 de 7 días frente a la línea base, capacidad de disco y
Change Tracking.

Si quieres comprobar por consola cómo va la subida:

```powershell
az monitor log-analytics query `
  --workspace 22178585-2404-433c-ae62-19d7dd5d99b8 `
  --analytics-query "InsightsMetrics | where TimeGenerated > ago(15m) | where Name in ('UtilizationPercentage','AvailableMB') | summarize avg(Val), max(Val) by Computer, Name" `
  -o table
```

### Paso 3.3 — Recuperación (minuto 50)

```powershell
# Ver qué queda, sin borrar nada
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID_DEL_PASO_3.1>

# Limpiar y comprobar la recuperación
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID_DEL_PASO_3.1> -Apply
```

Borra los recursos `perfops-*`, imprime la salida del payload (incluido el evento `5102` de cierre
con la memoria liberada) y consulta los últimos 10 minutos para confirmar que CPU y memoria han
vuelto por debajo de los umbrales.

> La media de 10 minutos puede seguir alta justo después de limpiar: la ventana todavía arrastra las
> muestras del pico. No es un fallo. Vuelve a lanzarlo un par de minutos después si quieres el número
> limpio.

### Paso 3.4 — Cierre

```powershell
.\scripts\verify-arc-fleet-observability.ps1
```

`0 fail` y cero `perfops-*`. El mensaje de cierre es que **el entorno queda exactamente como
estaba**: sin recursos huérfanos, sin memoria retenida, sin configuración modificada.

---

## 4. Si algo falla: los cuatro fallos reales

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `start-arc-fleet-pressure.ps1` se niega a arrancar | Quedan Run Command `perfops-*` de un ensayo anterior. Es un guard deliberado. | `.\scripts\recover-arc-fleet-pressure.ps1 -Apply -Confirm:$false` y reintenta. |
| El script se queda esperando una confirmación | Consola no interactiva. | Añade `-Confirm:$false` a `-Apply`. |
| Pasan 5 minutos y no sube nada | Latencia normal de despacho de Arc Run Command (1-3,5 min) más los 60 s de muestreo. | Esperar. Si a los 6 minutos sigue plano, comprueba que las máquinas están `Connected`. |
| Todo falla y no hay parque | `ArcBox-Client` apagada o no arrancada. | Plan B: sección 8. |

Comprobar el estado de un Run Command en vuelo:

```powershell
az resource list --resource-group rg-arcbox-itpro-weu-002 `
  --resource-type "Microsoft.HybridCompute/machines/runCommands" `
  --query "[?contains(name,'perfops')].{name:name}" -o table
```

Los eventos sintéticos de arranque y cierre del payload:

```powershell
az monitor log-analytics query `
  --workspace 22178585-2404-433c-ae62-19d7dd5d99b8 `
  --analytics-query "Event | where TimeGenerated > ago(30m) | where Source == 'Mercadona.FleetOps' | project TimeGenerated, Computer, EventID, RenderedDescription" `
  -o table
```

---

## 5. Lo que nunca hay que hacer

- No ampliar la lista blanca de máquinas. Solo `ArcBox-Win2K22` y `ArcBox-Win2K25` pueden recibir
  presión; `ArcBox-SQL`, los dos Ubuntu y la anfitriona están excluidos por diseño y el script los
  rechaza.
- No subir el agente de `Review` a `Autonomous` para "que quede mejor". El hecho de que proponga y no
  ejecute **es** el argumento de venta.
- No borrar recursos a mano en el portal. Usa siempre `recover-arc-fleet-pressure.ps1`.
- No lanzar la presión con menos de 30 minutos hasta el autoapagado de las 18:00 UTC.

---

## 6. Chuleta de recursos

| Qué | Dónde |
|---|---|
| Suscripción | `5305e853-a63b-4b82-9a3f-6fde18c1a798` |
| Inquilino | `9b1d3cd8-5db7-4564-905d-4d2eba7b66d5` |
| Grupo de recursos del parque Arc | `rg-arcbox-itpro-weu-002` (westeurope) |
| Máquinas Arc | `ArcBox-Win2K22`, `ArcBox-Win2K25`, `ArcBox-SQL`, `Arcbox-Ubuntu-01`, `Arcbox-Ubuntu-02` |
| Workspace | `law-arcbox-demo-001` — id `22178585-2404-433c-ae62-19d7dd5d99b8` |
| Libro | `ArcBox FleetOps - Azure Arc fleet observability` (`e24f4028-876f-5463-9f05-26142d6cf50b`) |
| Alertas Sev2 | `alert-arcbox-fleet-cpu-saturation`, `alert-arcbox-fleet-memory-pressure` |
| Grupo de acciones | `ag-mercadona-sre-demo` |
| Azure SRE Agent | `sre-agent-mercadona-v1` en `rg-mercadona-sre-agent-v1` (eastus2) |

Enlaces directos del portal:

- Libro:
  `https://portal.azure.com/#@9b1d3cd8-5db7-4564-905d-4d2eba7b66d5/resource/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.Insights/workbooks/e24f4028-876f-5463-9f05-26142d6cf50b`
- Agente:
  `https://portal.azure.com/#@9b1d3cd8-5db7-4564-905d-4d2eba7b66d5/resource/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-mercadona-sre-agent-v1/providers/Microsoft.App/agents/sre-agent-mercadona-v1`
- Alertas: portal → `rg-arcbox-itpro-weu-002` → **Alertas** → filtrar por gravedad `Sev2`.

Umbrales, para tenerlos a mano cuando pregunten: **CPU ≥ 85 %** y **memoria usada ≥ 80 %**, ambos
exigiendo **≥ 8 muestras de 60 segundos** dentro de una ventana de 15 minutos evaluada cada 5. Salen
de una línea base real de 7 días con un backtest de 344 ventanas y **cero disparos históricos**.

---

## 7. Tiempos reales medidos

Ensayo completo verificado, correlación `fleetops-20260803T103946Z-6d12e17a`:

| Hito | Medido |
|---|---|
| Lanzamiento → el payload arranca en el invitado | 1 – 3,5 min (latencia de despacho de Arc) |
| CPU en `ArcBox-Win2K25` | **94,2 % media / 96,8 % máx, 13 muestras infractoras** |
| Memoria en `ArcBox-Win2K22` | **82,0 % media / 83,0 % máx, 14 muestras infractoras**, suelo de 700 MB respetado |
| Lanzamiento → alerta Sev2 de memoria | **+10,6 min** |
| Lanzamiento → alerta Sev2 de CPU | **+12,0 min** |
| Alerta → hilo de incidente en el SRE Agent | **+70 a +90 s** |
| **Lanzamiento → investigación del agente visible** | **~13 min** |
| Fin de la presión → alertas autoresueltas | 15 min sin muestras infractoras |

Lo que produjo el agente en ese ensayo, por si quieres anticiparlo en el guion: tabla de máquinas
mapeadas por rol, comparación contra la línea base documentada (**88,0 % observado frente a un p95 de
16,6 % = 5,8 veces**), veredicto de presión sostenida contando muestras (12 de 14) y correlación con
los eventos sintéticos `5101`/`5102`, declarados explícitamente como anotación de demo.

---

## 8. Plan B si no hay parque

Si `ArcBox-Client` no está disponible, el escenario sigue siendo presentable sin inyectar presión:

1. Recorrer el libro con datos históricos: los paneles de 7 días siguen teniendo datos.
2. Enseñar los umbrales y el backtest de 344 ventanas.
3. Enseñar la configuración del agente y lanzar a mano uno de los informes programados.
4. Sustituir la parte de incidente en directo por el recorrido de un hilo anterior en el historial
   del agente.
