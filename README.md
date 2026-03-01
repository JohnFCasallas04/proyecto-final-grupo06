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
2. Ejecute el comando ```docker compose up --build``` para caso de linux y ```docker-compose up --build``` en windows
3. Ejecute el script ```$ python Seguridad/scripts/check_reserva.py``` ubicándose en la raiz del proyecto
4. Valide el resultado en los archivos generados en la ruta ```Seguridad/scripts/``` con nombres ```valida_acceso.csv``` y ```valida_modificacion_reserva.csv```