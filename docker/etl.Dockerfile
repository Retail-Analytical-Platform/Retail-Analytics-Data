FROM python:3.14.7-slim

WORKDIR /app

COPY etl/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY etl/ ./etl/

CMD ["python", "etl/main.py"]
