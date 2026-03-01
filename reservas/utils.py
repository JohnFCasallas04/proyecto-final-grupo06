import requests
import hashlib
import json
import faker
import random


def generate_transaction_hash(transaction):
    # Convertir la transacción en una cadena JSON
    transaction_data = json.dumps(transaction, sort_keys=True)
    # Crear el hash SHA-256 de los datos
    return hashlib.sha256(transaction_data.encode('utf-8')).hexdigest()


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


def suspectUser(user):
    profile = get_user_profile(user)
    return profile != "viajero" and profile != "hoteles"


def get_user_profile(email):
    response = requests.get(f'http://usuarios:5001/users/{email}')
    if response.status_code == 200:
        return response.json().get('perfil')
    return None
