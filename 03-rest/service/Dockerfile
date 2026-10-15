# Базовый образ: Linux с установленным Python 3.12
FROM python:3.12-slim

# Рабочая папка внутри контейнера
WORKDIR /app

# Сначала ставим библиотеки (этот слой кэшируется и не пересобирается при правке кода)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Потом копируем код
COPY . .

# Команда запуска: uvicorn поднимает приложение app из файла main.py на порту 8000.
# --reload: при изменении main.py сервис перезапускается сам.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]