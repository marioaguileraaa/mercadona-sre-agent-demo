# Guía de demo: 60 minutos de observabilidad de flota Azure Arc con Azure SRE Agent

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

Público objetivo: equipo que opera AD FS y controladores de dominio on-premises conectados con Azure
Arc y quiere ver monitorización, visualización y asistencia del Azure SRE Agent sobre todo el parque.

Mensaje central: **Arc te da el plano de control; Azure Monitor te da la visión de todo el parque;
Azure SRE Agent convierte una alerta en una investigación con contexto y recomendaciones revisables,
sin tocar nada por su cuenta.**

## Antes de la sesión

### D-1

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798

# 1. Plan de infraestructura (what-if, no cambia nada)
.\scripts\deploy-arc-fleet-observability.ps1

# 2. Aplicar libro y las dos reglas Sev2
.\scripts\deploy-arc-fleet-observability.ps1 -Apply

# 3. Plan de configuración del agente (no cambia nada)
.\scripts\configure-arc-fleet-sre-agent.ps1

# 4. Aplicar skill, subagente, filtro Sev2 y los dos informes programados
.\scripts\configure-arc-fleet-sre-agent.ps1 -Apply

# 5. Verificación completa de solo lectura
.\scripts\verify-arc-fleet-observability.ps1
```

El paso 5 debe terminar con `0 fail`. Si hay `warn` por telemetría, es porque el parque ArcBox está
apagado fuera de su ventana diaria.

### D-0, 45 minutos antes

1. Confirmar que la VM anfitriona `ArcBox-Client` está encendida (arranca sola a las 08:00
   `Europe/Madrid` con `la-start-arcbox-client`) y que se autoapaga a las 18:00 UTC. **Si la demo cae
   cerca de las 18:00 UTC, adelantarla o reprogramar el apagado**: el escenario necesita al menos 30
   minutos de parque vivo.
2. Ejecutar `.\scripts\verify-arc-fleet-observability.ps1` otra vez.
3. Abrir en pestañas: el libro, la hoja de alertas de `rg-arcbox-itpro-weu-002`, y la interfaz del
   Azure SRE Agent.
4. Dejar una consola PowerShell abierta en la raíz del repositorio.

## Cronograma

| Tramo | Minutos | Contenido |
|---|---|---|
| 1 | 0-10 | Contexto, arquitectura y alcance |
| 2 | 10-13 | Lanzar la presión controlada |
| 3 | 13-30 | Recorrido del libro mientras sube la carga |
| 4 | 30-40 | Disparo de las alertas Sev2 y entrada del agente |
| 5 | 40-50 | Recomendaciones e informes programados |
| 6 | 50-60 | Recuperación, higiene y preguntas |

---

## Tramo 1 (0-10): contexto y arquitectura

Decir de entrada el marco: **demo técnica ficticia, datos sintéticos, ninguna afirmación sobre
operaciones reales**. Las máquinas se etiquetan como `adfs`, `domain-controller`, `identity-sql` y
`linux-edge` solo para narrar el patrón del cliente; no ejecutan AD FS ni AD DS.

Mostrar el diagrama mental en tres capas:

1. **Arc**: cinco servidores on-premises proyectados como recursos ARM. Identidad, RBAC, políticas,
   extensiones e inventario, sin abrir puertos de entrada.
2. **Azure Monitor**: un único Azure Monitor Agent por máquina alimenta `InsightsMetrics`,
   `Heartbeat`, `ConfigurationChange` y `Event` en `law-arcbox-demo-001`, con muestreo de 60 s.
3. **Azure SRE Agent**: consume las alertas Sev2, investiga con consultas KQL revisadas y devuelve
   hallazgos y recomendaciones en modo `Review`.

Insistir en el punto que más importa a un equipo de identidad: **no se ha instalado nada nuevo en los
servidores**. La regla de rendimiento que ya existía, `MSVMI-ama-vmi-default-dcr`, es la que
alimenta todo el escenario.

Mostrar también los umbrales y de dónde salen: línea base real de 7 días, backtest de 344 ventanas,
cero falsos positivos. Es el argumento que convierte "una alerta más" en "una alerta en la que se
puede confiar".

## Tramo 2 (10-13): lanzar la presión

Explicar primero la envolvente de seguridad, después ejecutar.

```powershell
# Plan: no cambia nada
.\scripts\start-arc-fleet-pressure.ps1

# Ejecutar
.\scripts\start-arc-fleet-pressure.ps1 -Apply
```

Puntos a decir en voz alta mientras se ejecuta:

- Solo dos máquinas de la lista blanca; el resto se rechaza por diseño.
- Perfil `Split`: `ArcBox-Win2K22` recibe memoria, `ArcBox-Win2K25` recibe CPU. Se disparan las dos
  reglas y se ven dos incidentes distintos.
- Techo duro de 2048 MB y suelo de 700 MB disponibles: el invitado nunca se queda sin memoria.
- Prioridad de proceso `BelowNormal`: el agente de Arc y el AMA siguen respondiendo.
- 14 minutos de duración con autoterminación; el `finally` libera todo pase lo que pase.
- Sin persistencia: ni tarea programada, ni servicio, ni reinicio.

Apuntar el `CorrelationId` que imprime el script. Se usará en el tramo 6.

## Tramo 3 (13-30): recorrido del libro

Este es el bloque que responde literalmente a lo que pidió el cliente. Recorrer el libro de arriba
abajo, sin prisa.

1. **Conectividad**: las cinco máquinas `Connected` y la versión del agente Arc. Esto es lo primero
   que un equipo de identidad quiere ver de un vistazo.
2. **Inventario**: rol de demo, sistema operativo, sitio y última comunicación. Explicar que en un
   parque real esta tabla se alimenta de etiquetas propias y se filtra por sitio o por dominio.
3. **Salud de extensiones**: las 29 extensiones agrupadas por capacidad y su estado de
   aprovisionamiento. **Es un panel que da valor el primer día**: cualquier extensión que no esté en
   `Succeeded` aparece aquí sin tener que entrar máquina por máquina.
4. **Cobertura de capacidades**: qué máquinas tienen AMA, Defender, Update Manager y Change
   Tracking. Sirve para detectar huecos de cobertura.
5. **Frescura de telemetría**: minutos desde el último `Heartbeat` y desde la última muestra de
   `InsightsMetrics`. Explicar la ventana operativa diaria de ArcBox para que nadie confunda el
   apagado nocturno con una avería.
6. **Series de CPU y memoria**: aquí ya empieza a verse subir la carga inyectada. Comparar la curva
   con la línea plana de las tres máquinas que no reciben presión.
7. **Instantánea de 15 minutos**: es exactamente lo que evalúan las alertas. Ver el contador de
   muestras que superan el umbral acercándose a 8.
8. **Resumen de rendimiento y p95 de 7 días frente a la línea base**: el panel que convierte un
   número en un juicio. Un 90 % de CPU no dice nada; un 90 % de CPU donde el p95 de siete días es
   9 % lo dice todo.
9. **Capacidad de disco**: por punto de montaje real. Mencionar que los pseudo-montajes de Linux se
   excluyen a propósito porque siempre reportan 0 % libre y generarían ruido permanente.
10. **Change Tracking**: qué cambió y cuándo. Es la pregunta que siempre sigue a "¿por qué ahora?".

Mientras se recorre, mostrar una o dos consultas KQL del repositorio para dejar claro que todo lo
que ve el agente son consultas **agregadas y revisadas**, versionadas en Git, sin volcados de datos
personales ni de mensajes de evento.

## Tramo 4 (30-40): las alertas y el agente

Las alertas deben aparecer entre 4 y 8 minutos después del inicio de la presión: 8 muestras de 60 s
más la latencia de ingesta y la cadencia de evaluación de 5 minutos.

1. Mostrar las dos alertas Sev2 disparadas, con el nombre `ArcBox FleetOps ...`.
2. Abrir el Azure SRE Agent y enseñar el hilo de incidente que ha abierto el filtro
   `arc-fleet-performance-sev2`.
3. Recorrer la investigación del subagente `arc-fleet-analyzer`. Responde en este orden:
   - qué máquinas y qué roles están afectados;
   - a cuánta distancia está el valor observado del p95 documentado de esa máquina;
   - si la presión es sostenida o un pico, contando muestras dentro de la ventana;
   - qué más cambió a la vez: extensiones, frescura, disco, Change Tracking y los eventos
     `Mercadona.FleetOps` `5101`/`5102`.
4. Señalar el marcador sintético: el agente correlaciona el evento `5101` con el pico y lo declara
   explícitamente como anotación de demo. Es la prueba de que distingue señal real de señal
   fabricada, que es justo lo que se le pide a un asistente en producción.

Si la sala pregunta "¿y si me equivoco de umbral?": recordar el backtest de 344 ventanas con cero
disparos. Y recordar que ambas reglas se autoresuelven a los 15 minutos sin muestras infractoras.

## Tramo 5 (40-50): recomendaciones e informes

1. Enseñar las recomendaciones del agente. Deben ser concretas, ordenadas y reversibles: identificar
   el proceso que consume, devolvérselo al responsable de la aplicación, revisar el
   dimensionamiento del invitado, escalar cualquier extensión que no esté en `Succeeded`, comprobar
   margen de disco antes de cualquier cambio.
2. **Enseñar el botón que no se pulsa.** El agente está en `Review`/`Low`: propone, no ejecuta.
   Nada se aplica sin aprobación humana explícita. Para un equipo de identidad esto no es un detalle,
   es la condición de entrada.
3. Mostrar las dos tareas programadas:
   - `arc-fleet-weekday-health-report`, cron `45 7 * * 1-5`: informe de salud de todo el parque cada
     mañana laborable, después de la ventana de arranque.
   - `arc-fleet-weekly-capacity-report`, cron `0 8 * * 1`: informe de capacidad y deriva de los
     últimos siete días frente a la línea base, con el margen que queda hasta los umbrales.
4. Explicar el valor operativo: el informe diario responde "¿está todo sano?" sin que nadie abra el
   portal, y el semanal responde "¿hacia dónde va esto?" antes de que sea un incidente.

## Tramo 6 (50-60): recuperación y preguntas

```powershell
# Ver qué queda, sin borrar nada
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID_DEL_TRAMO_2>

# Limpiar y verificar la recuperación
.\scripts\recover-arc-fleet-pressure.ps1 -CorrelationId <ID_DEL_TRAMO_2> -Apply
```

El script borra los recursos Run Command `perfops-*`, muestra la salida del payload y consulta los
últimos 10 minutos para confirmar que CPU y memoria han vuelto por debajo de los umbrales. Enseñar
también el evento `5102` de cierre con la memoria liberada.

Cerrar con la verificación final:

```powershell
.\scripts\verify-arc-fleet-observability.ps1
```

Y con el mensaje: **el entorno queda exactamente como estaba**. Ni recursos huérfanos, ni memoria
retenida, ni configuración modificada.

## Preguntas frecuentes y respuestas cortas

**¿Esto funciona con nuestros AD FS y DC reales?**
Sí, con los mismos componentes: Arc, un AMA por servidor y una regla de recopilación. Lo único que
cambiaría es que se añadirían contadores y eventos propios de AD FS y AD DS, y los umbrales se
calcularían con la línea base real de vuestro parque, igual que aquí.

**¿Qué permisos necesita el agente?**
En esta demo, exactamente tres: `Reader` y `Monitoring Reader` sobre el grupo de recursos, y
`Log Analytics Reader` sobre el workspace. Ninguno de escritura.

**¿Puede el agente reiniciar un servicio o un servidor?**
Con esta configuración no. Solo tiene herramientas de lectura y está en `Review`. Elevarlo sería una
decisión consciente y separada.

**¿Cuánto cuesta esto?**
El coste dominante es la ingesta en Log Analytics. En este parque, `InsightsMetrics` genera del
orden de 174 000 filas cada 24 horas para cinco máquinas. Es el número con el que se extrapola.

**¿Y si el servidor se queda sin memoria durante la demo?**
No puede: hay un techo duro de 2048 MB, un suelo de 700 MB disponibles comprobado antes de cada
asignación, y un bucle de mantenimiento que libera un trozo si el suelo se cruza por otra causa.

**¿Cómo evitáis los falsos positivos?**
Exigiendo 8 muestras de 60 segundos por encima del umbral dentro de una ventana de 15 minutos: 85 %
de CPU para la regla de saturación y 80 % de memoria usada para la de presión. Ambos umbrales salen
de una línea base real de 7 días y de un backtest de 344 ventanas que dio cero disparos.

## Plan B si el parque no arranca

Si `ArcBox-Client` no está disponible el día de la demo, el escenario sigue siendo presentable sin
inyectar presión:

1. Recorrer el libro con datos históricos (los paneles de 7 días siguen teniendo datos).
2. Enseñar los umbrales y el backtest.
3. Enseñar la configuración del agente y lanzar a mano el informe programado.
4. Sustituir el tramo 4 por el recorrido de un incidente anterior en el historial del agente.
