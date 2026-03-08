import hashlib
import hmac
import os
import sqlite3
from datetime import datetime

from flask import Flask, jsonify, request
from flask_restful import Api, Resource

app = Flask(__name__)
api = Api(app)

DB_PATH = os.getenv("TOKEN_DB_PATH", "/tmp/tarjetas.db")
TOKEN_PEPPER = os.getenv("TOKEN_PEPPER", "demo-pepper-change-me")


def init_db():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS tarjeta_tokens (
            token TEXT PRIMARY KEY,
            last4 TEXT NOT NULL,
            brand TEXT NOT NULL,
            exp_month INTEGER NOT NULL,
            exp_year INTEGER NOT NULL,
            holder TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    conn.commit()
    conn.close()


def luhn_valid(card_number):
    digits = [int(d) for d in card_number]
    checksum = 0
    parity = len(digits) % 2
    for idx, digit in enumerate(digits):
        if idx % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        checksum += digit
    return checksum % 10 == 0


def detect_brand(card_number):
    if card_number.startswith("4"):
        return "VISA"
    if card_number[:2] in {"51", "52", "53", "54", "55"}:
        return "MASTERCARD"
    if card_number[:2] in {"34", "37"}:
        return "AMEX"
    return "UNKNOWN"


def validate_card_data(data):
    required_fields = ["pan", "cvv", "exp_month", "exp_year", "holder"]
    missing_fields = [field for field in required_fields if field not in data]
    if missing_fields:
        return False, f"Missing fields: {', '.join(missing_fields)}"

    pan = "".join(ch for ch in str(data.get("pan")) if ch.isdigit())
    cvv = str(data.get("cvv", "")).strip()

    if not pan.isdigit() or not (13 <= len(pan) <= 19):
        return False, "Invalid PAN format"
    if not luhn_valid(pan):
        return False, "Invalid PAN (Luhn check failed)"
    if not cvv.isdigit() or len(cvv) not in {3, 4}:
        return False, "Invalid CVV format"

    try:
        exp_month = int(data.get("exp_month"))
        exp_year = int(data.get("exp_year"))
    except (TypeError, ValueError):
        return False, "Invalid expiration date"

    current_year = datetime.utcnow().year
    if exp_month < 1 or exp_month > 12:
        return False, "Invalid expiration month"
    if exp_year < current_year:
        return False, "Card expired"

    return True, "ok"


def tokenize_card(pan, exp_month, exp_year):
    # Token deterministico para la misma tarjeta en este escenario de prueba.
    payload = f"{pan}|{exp_month}|{exp_year}"
    digest = hmac.new(
        TOKEN_PEPPER.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return f"tok_{digest}"


def save_token(token, last4, brand, exp_month, exp_year, holder):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT OR REPLACE INTO tarjeta_tokens
            (token, last4, brand, exp_month, exp_year, holder, created_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            token,
            last4,
            brand,
            int(exp_month),
            int(exp_year),
            holder,
            datetime.utcnow().isoformat(),
        ),
    )
    conn.commit()
    conn.close()


class Health(Resource):
    def get(self):
        return jsonify({"status": "ok", "service": "tarjetas"})


class Tokenizar(Resource):
    def post(self):
        data = request.get_json() or {}
        valid, message = validate_card_data(data)
        if not valid:
            return jsonify({"message": message}), 400

        pan = "".join(ch for ch in str(data.get("pan")) if ch.isdigit())
        holder = str(data.get("holder", "")).strip()
        exp_month = int(data.get("exp_month"))
        exp_year = int(data.get("exp_year"))

        token = tokenize_card(pan, exp_month, exp_year)
        brand = detect_brand(pan)
        last4 = pan[-4:]

        save_token(token, last4, brand, exp_month, exp_year, holder)

        # Sobrescribimos datos sensibles para minimizar exposición en memoria.
        pan = ""
        data["cvv"] = ""

        return jsonify(
            {
                "message": "Tarjeta tokenizada",
                "card_token": token,
                "last4": last4,
                "brand": brand,
                "exp_month": exp_month,
                "exp_year": exp_year,
            }
        )


api.add_resource(Health, "/health")
api.add_resource(Tokenizar, "/tokenizar")


if __name__ == "__main__":
    init_db()
    app.run(debug=True, host="0.0.0.0", port=5003)
