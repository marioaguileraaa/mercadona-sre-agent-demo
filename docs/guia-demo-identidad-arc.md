# Guía de demo: identidad sintética con plumbing real de Azure Arc

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Mensaje principal

La demo muestra **Azure Arc, AMA, DCR, Log Analytics, Azure Monitor y Azure SRE Agent reales**, usando una fuente de eventos de identidad **sintética** porque los hosts no ejecutan AD FS ni AD DS. No presentar los eventos 4101/4102 como autenticaciones o fallos genuinos.

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

### 5. Recuperar

```powershell
.\scripts\recover-arc-identity-incident.ps1 `
  -CorrelationId 'SYNTH-ID-REEMPLAZAR'
```

Mostrar dos eventos 4102 agregados, uno por host, y esperar el auto-resolve.

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
