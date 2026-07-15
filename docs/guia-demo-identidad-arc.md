# Guía de demo: identidad sintética con plumbing real de Azure Arc

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Mensaje principal

La demo muestra **Azure Arc, AMA, DCR, Log Analytics, Azure Monitor y Azure SRE Agent reales**, usando una fuente de eventos de identidad **sintética** porque los hosts no ejecutan AD FS ni AD DS. No presentar los eventos 4101/4102 como autenticaciones o fallos genuinos.

## Ensayo validado (2026-07-15)

Todos los correlation IDs, identificadores de instancia, incidentes e hilos de esta sección son sintéticos. Todas las horas están expresadas en UTC.

| Evidencia | Resultado validado |
|---|---|
| Ejecución limpia | Correlation ID `SYNTH-ID-20260715T121108Z-C1D23058` |
| Ráfaga 4101 | `ArcBox-Win2K22`: 12 eventos, 12 secuencias distintas, primero a las 12:12:06Z. `ArcBox-Win2K25`: 12 eventos, 12 secuencias distintas, primero a las 12:13:24Z |
| Recuperación 4102 | Un marcador por host: Win2K22 a las 12:33:42Z y Win2K25 a las 12:36:03Z |
| Alerta | Instancia `d5cb21c6-07dc-5fb2-aa53-a116b1ec000e`, Sev2: `Fired` 12:13:29Z y `Resolved` 12:29:16Z, antes de ejecutar recovery |
| Azure SRE Agent | La nueva instancia se fusionó en el hilo existente `fd9d78e7-17b9-4442-bd85-2d479a888f52`; `mergedAlertCount=2`, con el nuevo incident ID asociado. Estado final `Complete/resolved`, `agentMode=Review`, sin acciones `critical` ni `warning` |
| Interpretación del agente | La investigación automática anterior del mismo hilo identificó correctamente los eventos sintéticos, confirmó Arc/AMA sanos, concluyó que no había preocupación real y no propuso remediación de identidad. La ejecución de 24 eventos fue un merge/deduplicación de alerta, no una investigación independiente nueva |
| Cleanup | Ambas máquinas `Connected`; cero Run Commands `identityops-*` |
| Verificador final | DCR exacta solo en Win2K22/Win2K25, otras asociaciones preservadas, AMA/Heartbeat/InsightsMetrics frescos, dos alertas Sev2 con auto-resolve, RBAC mínimo, conector/skill/subagente/filtro/tarea presentes y agente `Review/Low` |
| Hotfixes incluidos | PR #17 `88f5278c6e93f8239163d11f0cca84673caa5727` (Run Command PUT ARM `2025-01-13`, JSON `@file` UTF-8 sin BOM y script exacto); PR #18 `aeea96280835ea11f3bae971b0baa5623b86ff8d` (shape source top-level/nested); PR #19 `4d1e0b6c43160e16bf60eaeb2f56441b0a864e96` (LAW autoritativo e idempotencia/recovery con preflight global de ambos hosts) |
| Estado del repositorio | PR #16 de fixtures obsoletos cerrada; ninguna PR abierta antes de esta actualización documental |

## Preparación del día después de la configuración inicial

1. Confirmar la ejecución de `la-start-arcbox-client`, programada diariamente a las 08:00 en `Romance Standard Time`; iniciarla por el procedimiento Jumpstart solo si fuera necesario.
2. Esperar `Connected` en `ArcBox-Win2K22` y `ArcBox-Win2K25`.
3. Confirmar AMA `Succeeded`.
4. Seleccionar la suscripción exacta.
5. Ejecutar la verificación y no continuar si Heartbeat/InsightsMetrics no están frescos.

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\verify-arc-identity.ps1
```

## Preparación inicial, sin despliegue automático

Primero obtener los planes:

```powershell
.\scripts\deploy-arc-identity.ps1
.\scripts\configure-arc-identity-sre-agent.ps1
```

Tras revisión y aprobación explícita:

```powershell
.\scripts\deploy-arc-identity.ps1 -Apply -Confirm
.\scripts\configure-arc-identity-sre-agent.ps1 -Apply -Confirm
.\scripts\verify-arc-identity.ps1
```

Esta secuencia no cambia el frontend, la API retail, el escenario de memoria ni recursos de Jumpstart existentes.

Antes de esta configuración inicial es normal que LAW tenga Heartbeat e `InsightsMetrics`, pero no `Perf` ni `Event`. `Perf` permanece vacío por diseño: la DCR nueva añade solo `Event` y reutiliza las métricas de `MSVMI-ama-vmi-default-dcr`. El action group existente permanece habilitado sin receptores y no notifica al agente; el filtro de la plataforma Azure Monitor del SRE Agent detecta las Sev2.

La alerta de frescura se suprime fuera de la jornada esperada: 08:20 `Europe/Madrid`, después de 20 minutos de gracia, hasta el autoapagado `shutdown-computevm-ArcBox-Client` de las 18:00 UTC. `Europe/Madrid` aplica CET/CEST automáticamente; no presentar la ausencia nocturna de Heartbeat/InsightsMetrics como incidente.

## Checklist inmediato antes de la demo

- Ejecutar `.\scripts\verify-arc-identity.ps1` y exigir resultado correcto.
- Confirmar `ArcBox-Win2K22` y `ArcBox-Win2K25` en `Connected`.
- Confirmar cero Run Commands `identityops-*`.
- Usar un correlation ID sintético nuevo.
- Conservar Azure SRE Agent en `Review/Low`.

## Guion de 15 minutos

### 1. Explicar la arquitectura

Mostrar:

- dos servidores Windows anidados conectados de verdad por Azure Arc;
- AMA ya existente;
- DCR adicional solo de eventos, sin tocar ni duplicar VM Insights;
- workspace ArcBox y acción del SRE Agent existentes;
- agente en `Review/Low`.

Frase recomendada:

> El transporte, los hosts y la telemetría genérica son reales dentro del laboratorio. La señal de servicio de identidad está generada de forma sintética y marcada en cada evento.

### 2. Mostrar línea base

Ejecutar las consultas:

- `fleet-heartbeat.kql`;
- `data-freshness.kql`;
- `performance-correlation.kql`;
- `extension-health.arg.kql`.

No mostrar mensajes de eventos ni nombres de usuario.

La referencia auditada de dos horas es: Win2K22 CPU 4,38 % media/11,51 % p95, memoria ~2,53 GB, disco ~1 ms y 80,31 % libre; Win2K25 CPU 9,71 %/19,32 %, memoria ~2,19 GB, disco ~1,1-1,3 ms y 58,73 % libre. Presentarla como contexto informativo, no como SLO ni umbral. Este POC no crea alertas por valores de rendimiento.

### 3. Generar la ráfaga

```powershell
.\scripts\start-arc-identity-incident.ps1
```

Anotar el correlation ID. La ejecución predeterminada produce 12 eventos por host, 24 en total, y no puede superar 20 por host.

### 4. Seguir la señal

1. Confirmar el agregado en `synthetic-token-failure-burst.kql`.
2. Mostrar la alerta Sev2.
3. Abrir la investigación del SRE Agent.
4. Comprobar que el agente:
   - etiqueta la identidad como sintética;
   - correlaciona Heartbeat, InsightsMetrics existente, Event, extensiones y cambios;
   - no expone datos personales;
   - no ejecuta remediación;
   - deja recomendaciones para revisión humana.

Si el agente trata la señal como un ataque real o propone cambios de identidad, rechazar la salida y señalar el fallo de gobierno.

En demos repetidas, Azure SRE Agent puede fusionar una alerta nueva de la misma regla en el hilo existente. Comprobar que el incident ID nuevo esté asociado y revisar `mergedAlertCount`; no esperar necesariamente un thread ID nuevo. En una primera ejecución limpia sí debe aparecer la investigación automática. Nunca forzar remediación para producir otra investigación.

### 5. Recuperar

```powershell
.\scripts\recover-arc-identity-incident.ps1 `
  -CorrelationId 'SYNTH-ID-REEMPLAZAR'
```

La alerta se auto-resuelve cuando los eventos 4101 salen de la ventana móvil de cinco minutos. Los dos eventos 4102, uno por host, son marcadores de recuperación auditables e idempotentes; no forman parte de la condición KQL que causa el auto-resolve. Mostrar ambos marcadores y confirmar por separado el estado de la alerta. En el ensayo validado, la alerta se resolvió antes de ejecutar recovery.

### 6. Mostrar el informe

La tarea `identity-infrastructure-weekday-report` se ejecuta a las 07:30 UTC de lunes a viernes: 08:30 CET o 09:30 CEST, siempre después de la gracia de arranque. El informe debe cubrir:

- Arc/AMA y frescura;
- rendimiento agregado;
- recuentos 4101/4102 sintéticos;
- salud de extensión y recuentos de change tracking solo si la capacidad ya existe; en caso contrario, declarar la señal no disponible;
- recomendaciones bajo Review;
- escalado al SOC/Sentinel si apareciera evidencia real.

## Criterios de aceptación de la demo

- La aplicación retail no cambia.
- DCR/asociaciones existentes permanecen.
- Solo los dos Windows reciben la DCR nueva.
- La ráfaga y recuperación son exactas, acotadas e idempotentes por correlation ID.
- No queda Run Command.
- El agente permanece Review/Low.
- La narrativa separa telemetría real y eventos de identidad sintéticos.
- El cierre incluye recuperación y resolución de alerta.

## Adaptación para un cliente

Explicar que el paso a producción requiere:

1. inventario real de granjas AD FS y DC;
2. DCR separadas por rol/entorno/región;
3. baseline de volumen antes de activar eventos;
4. AD FS/Admin 1201/1203/364 como candidatos de fallo;
5. Directory Service/System para salud y replicación;
6. Security mediante Microsoft Sentinel y gobierno del SOC;
7. minimización de PII, RBAC, retención y residencia;
8. pruebas de carga, alert tuning y runbooks aprobados;
9. ninguna remediación autónoma de identidad.

La matriz completa está en [`arquitectura-identidad-arc.md`](arquitectura-identidad-arc.md) y el procedimiento operativo en [`runbooks/arc-identidad-operaciones.md`](runbooks/arc-identidad-operaciones.md).
