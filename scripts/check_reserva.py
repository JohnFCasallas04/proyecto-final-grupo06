import requests
from validacion_auth import login_user
import json
import random
from datetime import datetime
import faker


def log(iteration_id, timestamp, id_reserva, estado, mensaje):
    """Registra logs en formato JSON para análisis estadístico."""
    log_entry = {
        "timestamp": timestamp,
        "id_reserva": id_reserva,
        "estado": estado,
        "mensaje": mensaje

    }
    with open('scripts/valida_modificacion_reserva.csv', 'a+', encoding='utf-8') as f:
        f.write('{id}\t{fecha}\t{id_reserva}\t{estado}\t{mensaje}'.format(id=iteration_id, fecha=datetime.now(
        ).isoformat(), id_reserva=log_entry.get('id_reserva'), estado=log_entry.get('estado'), mensaje=log_entry.get('mensaje')) + '\n')
    return f'Logged message: {json.dumps(log_entry)}'


def generar_datos_reservas(reserva_id, creada=False):
    fake = faker.Faker()
    if creada:
        estado = ["pendiente"]
    else:
        estado = ["pendiente", "aprobada"]
    return {
        "id": reserva_id,
        "id_usuario": fake.random_int(min=1, max=100),
        "id_propiedad": fake.random_int(min=1, max=100),        
        "estado": random.choice(estado),
        "codigo_moneda": "USD",
        "payment": {
            "card": {
                "pan": fake.credit_card_number(card_type="visa"),
                "cvv": fake.credit_card_security_code(card_type="visa"),
                "exp_month": int(fake.credit_card_expire(start="now", end="+3y", date_format="%m")),
                "exp_year": int(fake.credit_card_expire(start="now", end="+3y", date_format="%Y")),
                "holder": fake.name()
            }
        },
        "checkSum": ""
    }


def validar_reserva(iteration_id, timestamp):
    login, _ = login_user()
    token = login.get("token")
    ids = list(range(1, 20))
    url = f"http://localhost/reservas/{random.choice(ids)}"
    headers = {
        "Authorization": "Bearer " + token
    }
    data = generar_datos_reservas(random.choice(ids))
    response = requests.put(url, headers=headers, json=data, timeout=10)
    response = response.json()
    log(iteration_id, timestamp, response.get('id_reserva'),
        data.get("estado"), response.get('message'))
    print(response, timestamp)


for i in range(100):
    current_timestamp = datetime.now().isoformat()
    validar_reserva(i, current_timestamp)
