import requests as req
import random
from datetime import datetime
import json

def log(usuario, perfil, autorizado):
    """Registra logs en formato JSON para análisis estadístico."""
    log_entry = {
        "timestamp": datetime.now().isoformat(),
        "usuario": usuario,
        "perfil": perfil,
        "autorizado": autorizado
        
    }
    with open('scripts/valida_acceso.csv', 'a+') as f:
        f.write('{fecha}\t{usuario}\t{perfil}\t{autorizado}'.format(fecha=datetime.now(
        ).isoformat(), usuario=log_entry.get('usuario'), perfil=log_entry.get('perfil'), autorizado=log_entry.get('autorizado')) + '\n')
    return f'Logged message: {json.dumps(log_entry)}'

def validar_auth():
    login, data_user = login_user()
    token = login.get("token")
    url = "http://localhost/reservas"
    headers = {
        "Authorization": "Bearer " + token
    }
    response = req.get(url, headers=headers)
    log(data_user.get("email"), data_user.get("perfil"), response.json().get('message'))


def login_user():
    user = get_random_user()
    data = {
        "email": user.get("email"),
        "password": user.get("password")
    }
    url = "http://localhost/usuarios/login"
    response = req.post(url, json=data)
    return response.json(), {"perfil" : user.get("perfil"), "email" : user.get("email")}
    

def get_users():    
    url = "http://localhost/usuarios/users"
    response = req.get(url)
    users = response.json().get("users")
    return users

def get_random_user():
    users = get_users()
    users_list = []
    users_list_v = []
    
    
    for user in users:
            if user.get("perfil") != "viajero" and user.get("perfil") != "hoteles" and user.get("perfil") != "administrador":
                users_list.append(user)
            else:
                users_list_v.append(user)
                
    if random.random() < 0.5:        
        return random.choice(users_list)
    else:
        return random.choice(users_list_v)
    

for i in range(1000):
    validar_auth()