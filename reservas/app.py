from flask import Flask, request, jsonify
from flask_restful import Api, Resource
from flask_jwt_extended import JWTManager, jwt_required, get_jwt_identity
import requests
from utils import get_user_profile, generate_transaction_hash, generar_datos_reservas

app = Flask(__name__)
app.config["JWT_SECRET_KEY"] = "secret-jwt"  # Change this!
app.config["JWT_ACCESS_TOKEN_EXPIRES"] = False
jwt = JWTManager(app)
api = Api(app)

reservasListar = [generar_datos_reservas(i, True) for i in range(1, 20)]



class Reserva(Resource):

    @jwt_required()
    def get(self):
        # Obtener la identidad del usuario desde el token JWT
        current_user = get_jwt_identity()
        print(f"The current user is {current_user}")
        # Obtener el perfil del usuario
        perfil = get_user_profile(current_user)
        print(f"The current user profile is {perfil}")
        if perfil is None:
            return jsonify({"message": "User profile not found"})
        # Validación del tipo de usuario
        # intruder = suspectUser(current_user)
        if perfil != "viajero" and perfil != "hoteles" and perfil != "administrador":
            return jsonify({"message": "Unauthorized"})
        # Aquí puedes agregar la lógica para manejar la solicitud GET
        return jsonify({"message": "Authorized", "user": current_user, "perfil": perfil})

    @jwt_required()
    def put(self, id_reserva):
        # Obtener los datos de la solicitud
        data = request.get_json() or {}

        payment = data.get("payment") or {}
        card_data = payment.get("card")
        if card_data:
            try:
                token_response = requests.post(
                    "http://tarjetas:5003/tokenizar", json=card_data, timeout=5
                )
            except requests.RequestException:
                return jsonify({"message": "No fue posible tokenizar la tarjeta"}), 502

            if token_response.status_code != 200:
                try:
                    response_json = token_response.json()
                except ValueError:
                    response_json = {}
                return jsonify({"message": response_json.get("message", "Error de tokenizacion")}), 400

            tokenized = token_response.json()
            data["payment"] = {
                "card_token": tokenized.get("card_token"),
                "last4": tokenized.get("last4"),
                "brand": tokenized.get("brand")
            }
        else:
            current_payment = payment if isinstance(payment, dict) else {}
            data["payment"] = {
                "card_token": current_payment.get("card_token", ""),
                "last4": current_payment.get("last4", ""),
                "brand": current_payment.get("brand", "")
            }

        new_check = generate_transaction_hash(data)

        # Buscar la reserva con el id_reserva proporcionado
        reserva = next(
            (reserva for reserva in reservasListar if reserva["id"] == id_reserva), None)

        # Si la reserva no existe
        if reserva is None:
            return jsonify({"message": "Reserva no encontrada"})

        # Datos a actualizar
        updated_fields = {
            'id_usuario': data.get('id_usuario'),
            'id_propiedad': data.get('id_propiedad'),
            'codigo_moneda': data.get('codigo_moneda'),
            'estado': data.get('estado'),
            'payment': data.get('payment')
        }

        # Lógica para manejar las reservas en diferentes estados
        if reserva['checkSum'] == '':
            # Si el checkSum está vacío y el estado no es 'aprobada'
            if data.get('estado') != 'aprobada':
                for key, value in updated_fields.items():
                    reserva[key] = value
                return jsonify({"message": "Reserva actualizada", "id_reserva": reserva.get('id')})

            # Si el estado es 'aprobada', asignamos el checkSum
            elif data.get('estado') == 'aprobada':
                for key, value in updated_fields.items():
                    reserva[key] = value
                reserva["checkSum"] = new_check
                return jsonify({"message": "Reserva aprobada", "id_reserva": reserva.get('id')})

        # Si el checkSum ya existe y no hay cambios
        elif reserva['checkSum'] == new_check:
            return jsonify({"message": "Sin cambios", "id_reserva": reserva.get('id')})

        # Si la reserva ya está aprobada, no se puede modificar
        else:
            return jsonify({"message": "No es posible realizar cambios a una reserva aprobada", "id_reserva": reserva.get('id')})


api.add_resource(Reserva, '/reservas', '/reservas/<int:id_reserva>')

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5002)
