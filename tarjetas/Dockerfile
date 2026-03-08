FROM python:3.12

WORKDIR /app

COPY app.py requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 5003

CMD ["python", "-u", "app.py"]
