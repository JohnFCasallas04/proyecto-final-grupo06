import json
import os
import time
import uuid
from functools import lru_cache

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException
from pydantic import AliasChoices, BaseModel, Field


app = FastAPI(title="TravelHub - API Producer")

AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
SQS_ENDPOINT_URL = os.getenv("SQS_ENDPOINT_URL")
SQS_QUEUE_NAME = os.getenv("SQS_QUEUE_NAME", "ReservasQueue")
QUEUE_INIT_RETRIES = int(os.getenv("QUEUE_INIT_RETRIES", "20"))
QUEUE_INIT_BACKOFF_SECONDS = float(os.getenv("QUEUE_INIT_BACKOFF_SECONDS", "1.0"))


class PaymentRequest(BaseModel):
    amount: float = Field(
        gt=0,
        validation_alias=AliasChoices("amount", "cantidad"),
        serialization_alias="amount",
    )
    currency: str = Field(
        min_length=3,
        max_length=3,
        validation_alias=AliasChoices("currency", "moneda"),
        serialization_alias="currency",
    )
    stress_time: float = Field(
        default=0.5,
        ge=0.1,
        le=30.0,
        validation_alias=AliasChoices("stress_time", "tiempo_estres"),
        serialization_alias="stress_time",
    )


@lru_cache(maxsize=1)
def get_sqs_client():
    return boto3.client(
        "sqs",
        region_name=AWS_REGION,
        endpoint_url=SQS_ENDPOINT_URL or None,
    )


@lru_cache(maxsize=1)
def get_queue_url() -> str:
    sqs_client = get_sqs_client()
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


@app.get("/health")
def health_check():
    return {"status": "healthy"}


@app.post("/api/v1/payments", status_code=202)
def receive_payment(payment: PaymentRequest):
    transaction_id = str(uuid.uuid4())
    message = {
        "transaction_id": transaction_id,
        "amount": payment.amount,
        "currency": payment.currency.upper(),
        "stress_time": payment.stress_time,
    }

    try:
        sqs_client = get_sqs_client()
        queue_url = get_queue_url()
        sqs_client.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(message),
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Error queueing transaction") from exc

    return {
        "status": "processing",
        "transaction_id": transaction_id,
        "message": "Payment received and queued. Asynchronous processing started.",
    }
