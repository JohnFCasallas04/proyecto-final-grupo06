import requests
from validacion_auth import login_user
import json
import random
from datetime import datetime
import faker


def log(id, date, id_reserva, estado, mensaje):
    """Registra logs en formato JSON para análisis estadístico."""
    log_entry = {
        "timestamp": date,
        "id_reserva": id_reserva,
        "estado": estado,
        "mensaje": mensaje

    }
    with open('Seguridad/scripts/valida_modificacion_reserva.csv', 'a+') as f:
        f.write('{id}\t{fecha}\t{id_reserva}\t{estado}\t{mensaje}'.format(id=id, fecha=datetime.now(
        ).isoformat(), id_reserva=log_entry.get('id_reserva'), estado=log_entry.get('estado'), mensaje=log_entry.get('mensaje')) + '\n')
    return f'Logged message: {json.dumps(log_entry)}'


def generar_datos_reservas(id, creada=False):
    fake = faker.Faker()
    if creada:
        estado = ["pendiente"]
    else:
        estado = ["pendiente", "aprobada"]
    return {
        "id": id,
        "id_usuario": fake.random_int(min=1, max=100),
        "id_propiedad": fake.random_int(min=1, max=100),        
        "estado": random.choice(estado),
        "codigo_moneda": "USD",
        "checkSum": ""
    }


def validar_reserva(id, date):
    login, data_user = login_user()
    token = login.get("token")
    ids = list(range(1, 20))
    url = f"http://localhost/reservas/{random.choice(ids)}"
    headers = {
        "Authorization": "Bearer " + token
    }
    data = generar_datos_reservas(random.choice(ids))
    response = requests.put(url, headers=headers, json=data)
    response = response.json()
    log(id, date, response.get('id_reserva'),
        data.get("estado"), response.get('message'))
    print(response, date)


for i in range(100):
    date = datetime.now().isoformat()
    validar_reserva(i, date)
