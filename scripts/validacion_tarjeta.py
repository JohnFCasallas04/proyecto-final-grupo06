import csv
import re
import sqlite3
from datetime import datetime
from pathlib import Path

PAN_REGEX = re.compile(r"\b\d{13,19}\b")


def luhn_valid(number):
    digits = [int(d) for d in number]
    checksum = 0
    parity = len(digits) % 2
    for idx, digit in enumerate(digits):
        if idx % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        checksum += digit
    return checksum % 10 == 0


def find_plaintext_pan(text):
    matches = []
    for candidate in PAN_REGEX.findall(text):
        if luhn_valid(candidate):
            matches.append(candidate)
    return matches


def count_findings_in_text_file(path):
    if not path.exists():
        return 0

    findings = 0
    with path.open("r", encoding="utf-8", errors="ignore") as file_obj:
        for line in file_obj:
            findings += len(find_plaintext_pan(line))
    return findings


def count_findings_in_db(path):
    if not path.exists():
        return 0

    findings = 0
    conn = sqlite3.connect(path)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [row[0] for row in cursor.fetchall()]

    for table in tables:
        cursor.execute(f"PRAGMA table_info({table})")
        columns = [row[1] for row in cursor.fetchall()]
        if not columns:
            continue

        cursor.execute(f"SELECT {', '.join(columns)} FROM {table}")
        rows = cursor.fetchall()
        for row in rows:
            row_text = " ".join(str(value) for value in row if value is not None)
            findings += len(find_plaintext_pan(row_text))

    conn.close()
    return findings


def has_strings(path, required_strings):
    if not path.exists():
        return False
    content = path.read_text(encoding="utf-8", errors="ignore")
    return all(item in content for item in required_strings)


def main():
    repo_root = Path(__file__).resolve().parent.parent
    timestamp = datetime.now().isoformat()

    tarjetas_app = repo_root / "tarjetas" / "app.py"
    reservas_app = repo_root / "reservas" / "app.py"
    reservas_utils = repo_root / "reservas" / "utils.py"

    db_files = list((repo_root / "tarjetas" / "data").glob("*.db"))

    text_files = [
        repo_root / "scripts" / "valida_acceso.csv",
        repo_root / "scripts" / "valida_modificacion_reserva.csv",
    ]

    total_findings = 0
    for file_path in text_files:
        total_findings += count_findings_in_text_file(file_path)
    for db_file in db_files:
        total_findings += count_findings_in_db(db_file)

    control_1 = has_strings(
        tarjetas_app,
        ["def tokenize_card", "hmac.new", "hashlib.sha256", '"/tokenizar"'],
    )
    control_2 = has_strings(
        reservas_app,
        ['payment.get("card")', 'http://tarjetas:5003/tokenizar', '"card_token"'],
    )
    control_3 = has_strings(
        reservas_utils,
        ["def generate_transaction_hash", "hashlib.sha256"],
    ) and has_strings(reservas_app, ["generate_transaction_hash(data)", "checkSum"])
    control_4 = len(db_files) > 0 and total_findings == 0

    rows = [
        [
            timestamp,
            "token_irreversible_tarjeta",
            "OK" if control_1 else "ALERTA",
            "Existe tokenizacion irreversible",
        ],
        [
            timestamp,
            "transformacion_inmediata_token",
            "OK" if control_2 else "ALERTA",
            "Reservas transforma tarjeta a token",
        ],
        [
            timestamp,
            "checksum_integridad",
            "OK" if control_3 else "ALERTA",
            "Checksum SHA-256 activo en reservas",
        ],
        [
            timestamp,
            "no_tarjeta_texto_plano",
            "OK" if control_4 else "ALERTA",
            f"Hallazgos PAN en texto plano: {total_findings}",
        ],
    ]

    output_csv = repo_root / "scripts" / "valida_tarjeta.csv"
    with output_csv.open("w", encoding="utf-8", newline="") as file_obj:
        writer = csv.writer(file_obj)
        writer.writerow(["timestamp", "control", "resultado", "detalle"])
        writer.writerows(rows)

    print("Reporte generado:", output_csv)
    for row in rows:
        print(f"- {row[1]}: {row[2]} | {row[3]}")


if __name__ == "__main__":
    main()
