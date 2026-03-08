from flask import Flask, request, jsonify
from flask_restful import Api, Resource
from flask_jwt_extended import create_access_token, JWTManager
import requests

users = [
    {
        "id": 1,
        "name": "John",
        "email": "john@uniandes.edu.co",
        "password": "1234",
        "perfil": "viajero"
    },
    {
        "id": 2,
        "name": "Diego",
        "email": "diego@uniandes.edu.co",
        "password": "5678",
        "perfil": "espectador"
    },
    {
        "id": 3,
        "name": "Jose",
        "email": "jose@uniandes.edu.co",
        "password": "9012",
        "perfil": "administrador"
    },
    {
        "id": 4,
        "name": "Nicolas",
        "email": "nicolas@uniandes.edu.co",
        "password": "3456",
        "perfil": "hoteles"
    }
]

app = Flask(__name__)
app.config["JWT_SECRET_KEY"] = "secret-jwt"  # Change this!
jwt = JWTManager(app)
api = Api(app)

class Login(Resource):
    def post(self):
        data = request.get_json()
        email = data["email"]
        password = data["password"]
        for user in users:
            if user["email"] == email and user["password"] == password:
                access_token = requests.get(f"http://seguridad:5000/jwt/{email}").json().get("access_token")
                return jsonify({"message": "User logged in", "user_id": user.get('id'), "user_perfil": user.get("perfil"), "token": access_token})
        return jsonify({"message": "User not found"}), 401

class Users(Resource):
    def get(self):
        return jsonify({"users": users})

class UserProfile(Resource):
    def get(self, email):
        for user in users:
            if user["email"] == email:
                return jsonify({"perfil": user["perfil"]})
        return jsonify({"message": "User not found"}), 404

api.add_resource(Login, '/login')
api.add_resource(Users, '/users')
api.add_resource(UserProfile, '/users/<string:email>')

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5001)