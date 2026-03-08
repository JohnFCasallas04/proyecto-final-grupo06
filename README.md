# Experimento Seguridad

## Integrantes del Proyecto

| Nombre            |Correo                                |
|-------------------|--------------------------------------|
| Diego Santamaria  |jd.santamariab1@uniandes.edu.co       |
| Nicolas Caicedo   |ng.caicedo@uniandes.edu.co            |
| Jose Rodriguez    |jd.rodriguezg1234567@uniandes.edu.co  |
| John Casallas     |j.casallasp@uniandes.edu.co           |

## Pasos para ejecutar el aplicativo
1. Clone el repositorio en su equipo local. Como requisitos debe tener instalado python y docker
2. Ubicandose en la raiz del proyecto, ejecute `docker compose up --build` (Linux/Mac) o `docker-compose up --build` (Windows)
3. En otra terminal, ejecute `python scripts/validacion_auth.py` para generar evidencias de autorizacion
4. En otra terminal, ejecute `python scripts/check_reserva.py` para generar flujo de reservas y tokenizacion de tarjeta
5. Ejecute `python scripts/validacion_tarjeta.py` para generar el reporte de controles de tarjeta

## Evidencias generadas
Los archivos de salida quedan en `scripts/`:

- `valida_acceso.csv`: evidencia de autorizacion por perfil
- `valida_modificacion_reserva.csv`: evidencia de cambios/estado de reservas
- `valida_tarjeta.csv`: evidencia de controles de tarjeta (tokenizacion, transformacion inmediata, checksum e inspeccion de texto plano)

## Experimento limpio (opcional)
Si desea reiniciar la prueba de tarjeta en limpio:

1. Detenga contenedores con `docker compose down --volumes --remove-orphans`
2. Elimine bases de tarjeta con `rm -f tarjetas/data/*.db` (bash) o `Remove-Item .\tarjetas\data\*.db -Force` (PowerShell)
3. Vuelva a iniciar con `docker compose up --build`

## Notas del escenario
- Este repositorio es un escenario de experimentacion academica de seguridad.
- La validacion de tarjeta usa deteccion de PAN en texto plano con regex + Luhn sobre CSV y bases `.db` del servicio `tarjetas`.