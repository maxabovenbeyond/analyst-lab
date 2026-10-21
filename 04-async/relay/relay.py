"""
Outbox relay — «курьер»: забирает неотправленные события из delivery.outbox
и публикует их в Kafka. Гарантия: at-least-once (возможны дубли, потери — нет).
"""
import json
import os
import time

import psycopg
from psycopg.rows import dict_row
from confluent_kafka import Producer

DATABASE_URL = os.environ["DATABASE_URL"]
KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "kafka:29092")
TOPIC = "order-events"
BATCH_SIZE = 100      # сколько событий забираем за один заход
PAUSE_SECONDS = 1.0   # как часто проверяем лоток

producer = Producer({
    "bootstrap.servers": KAFKA_BOOTSTRAP,
    "acks": "all",                 # ждать подтверждения записи от Kafka
    "enable.idempotence": True,    # сам продюсер не задвоит сообщение при своих повторах
    "message.timeout.ms": 5000,    # если Kafka не ответила за 5 с — считаем отправку неудачной
})


def publish_batch() -> int:
    """Один заход курьера. Возвращает число опубликованных событий."""
    with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:   # одна транзакция
        rows = conn.execute(
            """
            SELECT id, aggregate_id, event_type, event
            FROM delivery.outbox
            WHERE published_at IS NULL
            ORDER BY id                 -- в порядке создания: порядок событий заказа сохраняется
            LIMIT %s
            FOR UPDATE SKIP LOCKED      -- если курьеров несколько, они не возьмут одно и то же
            """,
            (BATCH_SIZE,),
        ).fetchall()
        if not rows:
            return 0

        errors = []

        def on_delivery(err, msg):
            if err is not None:
                errors.append(str(err))

        for r in rows:
            producer.produce(
                TOPIC,
                key=r["aggregate_id"],                 # ключ = order_id → одна партиция на заказ
                value=json.dumps(r["event"], ensure_ascii=False).encode(),
                headers={"event_type": r["event_type"]},
                on_delivery=on_delivery,
            )
        not_delivered = producer.flush(10)             # ждём подтверждения от Kafka

        if not_delivered or errors:
            # Исключение → транзакция откатится → published_at не проставится → событие уйдёт позже
            raise RuntimeError(f"Kafka не подтвердила отправку: {errors or not_delivered}")

        conn.execute(
            "UPDATE delivery.outbox SET published_at = now() WHERE id = ANY(%s)",
            ([r["id"] for r in rows],),
        )
        for r in rows:
            print(f"  → {r['event_type']} заказ {r['aggregate_id']}", flush=True)
        return len(rows)


def main():
    print("Outbox relay запущен", flush=True)
    while True:
        try:
            published = publish_batch()
            if published:
                print(f"опубликовано: {published}", flush=True)
        except Exception as exc:
            print(f"ошибка, повтор через 5 с: {exc}", flush=True)
            time.sleep(5)
            continue
        time.sleep(PAUSE_SECONDS)


if __name__ == "__main__":
    main()