import json
import math
import os
import time

import boto3
from botocore.exceptions import ClientError


AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
SQS_ENDPOINT_URL = os.getenv("SQS_ENDPOINT_URL")
SQS_QUEUE_NAME = os.getenv("SQS_QUEUE_NAME", "ReservasQueue")
QUEUE_INIT_RETRIES = int(os.getenv("QUEUE_INIT_RETRIES", "20"))
QUEUE_INIT_BACKOFF_SECONDS = float(os.getenv("QUEUE_INIT_BACKOFF_SECONDS", "1.0"))
WAIT_TIME_SECONDS = int(os.getenv("SQS_WAIT_TIME_SECONDS", "10"))

sqs_client = boto3.client(
    "sqs",
    region_name=AWS_REGION,
    endpoint_url=SQS_ENDPOINT_URL or None,
)


def get_queue_url() -> str:
    last_error = None
    for _ in range(QUEUE_INIT_RETRIES):
        try:
            response = sqs_client.get_queue_url(QueueName=SQS_QUEUE_NAME)
            return response["QueueUrl"]
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code")
            if error_code == "AWS.SimpleQueueService.NonExistentQueue":
                try:
                    created = sqs_client.create_queue(QueueName=SQS_QUEUE_NAME)
                    return created["QueueUrl"]
                except ClientError as create_exc:
                    last_error = create_exc
            else:
                last_error = exc
        time.sleep(QUEUE_INIT_BACKOFF_SECONDS)

    raise RuntimeError(f"Could not initialize SQS queue '{SQS_QUEUE_NAME}': {last_error}")


def saturate_cpu(seconds_to_saturate: float) -> None:
    start_time = time.time()
    while time.time() - start_time < seconds_to_saturate:
        for i in range(10000):
            _ = math.sqrt(i)


def process_message(queue_url: str, message: dict) -> None:
    receipt_handle = message["ReceiptHandle"]
    body = message.get("Body", "{}")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        print("Invalid message; deleting from queue to avoid infinite retries.")
        sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
        return

    transaction_id = payload.get("transaction_id") or payload.get("transaccion_id", "unknown-id")
    stress_time = float(payload.get("stress_time", payload.get("tiempo_estres", 0.5)))
    print(f"Processing transaction {transaction_id} with CPU load of {stress_time}s")

    saturate_cpu(stress_time)
    sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
    print(f"Transaction {transaction_id} completed and deleted from SQS.")


def process_queue() -> None:
    queue_url = get_queue_url()
    print(f"Worker started. Listening to queue {SQS_QUEUE_NAME}...")

    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=WAIT_TIME_SECONDS,
            )

            messages = response.get("Messages", [])
            if not messages:
                continue

            for message in messages:
                process_message(queue_url, message)
        except Exception as exc:
            print(f"Error while processing messages: {exc}")
            time.sleep(1)


if __name__ == "__main__":
    process_queue()
