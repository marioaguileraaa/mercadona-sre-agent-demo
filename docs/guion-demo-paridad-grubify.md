# Guion: paridad segura con Grubify

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Apertura

“Esta demo reproduce el recorrido funcional de un incidente de memoria y 5xx, pero sustituye el OOM sin límite por un fallo determinista y acotado. No usa datos, operaciones ni activos oficiales.”

Muestra el flujo Stores -> Products -> Shopping Cart -> Checkout -> Order/Tracking y confirma que **Añadir** llama `POST /api/carts/{cartId}/items`.

## Preflight

Ejecuta:

```powershell
git fetch origin main
$expectedCommit = (git rev-parse origin/main).Trim()
.\scripts\verify-sre-agent.ps1 -ExpectedRepositoryCommit $expectedCommit
```

Di: “El agente está en Review/Low. El response plan solo coincide con la alerta Sev3 5xx y el backend exactos. CodeRepo está Ready en el SHA completo de origin/main y GitHub expone issue create/update, branch, contents/push y pull-request create; merge, workflows y deploy están denegados.”

Si aparece `INCOMPLETE`, detén la demo. Para permisos, usa **Builder > Connectors > GitHub OAuth > reconnect/authorize permissions for issues, contents and pull requests**. Para un SHA stale, usa **Builder > Knowledge base > Add repository**, reemplaza manualmente la fila stale y espera `Ready`. Después repite configure/verify con el mismo SHA; nunca copies tokens.

## Incidente

Ejecuta:

```powershell
.\scripts\start-incident.ps1
```

Mientras corre:

1. “La línea base debe estar sana y sin 5xx.”
2. “La revisión retiene 10 MiB por alta válida, con cap 640 MiB.”
3. “A 600 MiB el servicio deja de asignar y devuelve 503 con correlation ID.”
4. “El inyector termina tras seis 5xx o sus límites; nunca hay un loop infinito.”
5. “El script exige métrica >5, alerta Fired y thread nuevo. No recupera.”

Muestra el frontend con el error claro de carrito y correlation ID.

## Investigación y aprobación

En el thread, pide al operador que identifique:

- seis 5xx en Azure Monitor/App Insights;
- eventos `DEMO_CART_MEMORY_CAPACITY_EXHAUSTED` en Log Analytics;
- raíz fuerte sin expulsión en `CartMemoryRetentionService`;
- propuesta única: revisión limpia con per-add y failure a cero.

Di: “Nada se escribe hasta aprobación explícita.” Aprueba solo la revisión limpia.

Después confirma el issue y el PR con fix permanente. Di: “El agente no mergea ni despliega; el PR queda para revisión humana.”

## Recuperación

Si la mitigación del agente no se ejecuta o necesitas la vía de emergencia:

```powershell
.\scripts\recover-incident.ps1
```

Di: “Recovery es idempotente, crea una revisión limpia si hace falta y valida cesta, pedido y tracking. No mata procesos locales ni ajenos.”

## Cierre

Confirma variables a cero, flujo sano, alerta resuelta o warning de latencia, PR sin merge/deploy y disclaimer visible.
