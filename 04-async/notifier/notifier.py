"""
Сервис уведомлений: читает события заказов из Kafka и отправляет SMS / пуши (имитация).
- идемпотентность: журнал обработанных event_id (notify.processed_event)
- временные ошибки: до 3 попыток с паузами 1 и 2 с
- постоянные ошибки и исчерпанные попытки: сообщение уходит в DLQ (order-events.dlq)
- закладка (offset) фиксируется только ПОСЛЕ обработки: at-least-once
"""
import json
import os
import time

import psycopg
from confluent_kafka import Consumer, Producer

DATABASE_URL = os.environ["DATABASE_URL"]
KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "kafka:29092")
TOPIC = "order-events"
DLQ_TOPIC = "order-events.dlq"
GROUP = "notifications"
MAX_ATTEMPTS = 3
# Имитация сбоев SMS-шлюза: сколько первых попыток по каждому событию падает
FAIL_FIRST_ATTEMPTS = int(os.environ.get("FAIL_FIRST_ATTEMPTS", "0"))

consumer = Consumer({
    "bootstrap.servers": KAFKA_BOOTSTRAP,
    "group.id": GROUP,
    "auto.offset.reset": "earliest",   # новая группа читает топик с начала
    "enable.auto.commit": False,       # закладку двигаем сами, после обработки
})
dlq_producer = Producer({"bootstrap.servers": KAFKA_BOOTSTRAP})


class PermanentError(Exception):
    """Повтор не поможет (битый формат) — сразу в DLQ."""


attempts_by_event = {}


def send(channel: str, recipient: str, text: str, event_id: str) -> None:
    """Имитация SMS-шлюза и пуш-сервиса."""
    attempt = attempts_by_event.get(event_id, 0) + 1
    attempts_by_event[event_id] = attempt
    if attempt <= FAIL_FIRST_ATTEMPTS:
        raise ConnectionError(f"шлюз недоступен (попытка {attempt})")
    print(f"    [{channel}] {recipient}: {text}", flush=True)


def build_notifications(event: dict) -> list:
    """Какие уведомления нужны для события. Незнакомые типы — пропускаем (tolerant reader)."""
    t, p = event["event_type"], event["payload"]

    if t == "OrderPaid":
        return [("SMS", f"shop-{p['shop_id']}",
                 f"Новый оплаченный заказ №{p['order_id']} на {p['amount']} ₽. Примите его в кабинете.")]

    if t == "OrderCancelled":
        who = {
            "CUSTOMER": "Вы отменили заказ",
            "SHOP": "Магазин не смог принять заказ",
            "SUPPORT": "Заказ отменён службой поддержки:",
            "SYSTEM": "Заказ отменён автоматически:",
        }[p["cancelled_by"]]
        text = f"{who} №{p['order_id']}."
        if p["paid_amount"] > 0:
            text += f" {p['paid_amount']} ₽ вернутся на карту в течение 3 рабочих дней."
        result = [("PUSH", f"customer-{p['customer_id']}", text)]
        if p["previous_status"] in ("ASSEMBLING", "AWAITING_COURIER"):
            result.append(("SMS", f"shop-{p['shop_id']}",
                           f"Заказ №{p['order_id']} отменён. Сборку можно прекратить."))
        return result

    return []


def handle(msg) -> None:
    # Разбор: любая ошибка здесь — постоянная
    try:
        event = json.loads(msg.value())
        event_id, event_type = event["event_id"], event["event_type"]
        notifications = build_notifications(event)
    except (ValueError, KeyError, TypeError) as exc:
        raise PermanentError(f"неверный формат события: {exc!r}")

    with psycopg.connect(DATABASE_URL) as conn:   # одна транзакция: журнал + уведомления
        first_time = conn.execute(
            """INSERT INTO notify.processed_event (event_id, event_type) VALUES (%s, %s)
               ON CONFLICT (event_id) DO NOTHING RETURNING event_id""",
            (event_id, event_type),
        ).fetchone()
        if first_time is None:
            print(f"  DUPLICATE {event_type} {event_id} — уже обработано, пропускаем", flush=True)
            return

        for channel, recipient, text in notifications:
            send(channel, recipient, text, event_id)          # ошибка шлюза → откат транзакции
            conn.execute(
                """INSERT INTO notify.notification (event_id, channel, recipient, text)
                   VALUES (%s, %s, %s, %s)""",
                (event_id, channel, recipient, text),
            )
        print(f"  OK {event_type}, уведомлений: {len(notifications)}", flush=True)


def to_dlq(msg, reason: str) -> None:
    """Откладываем сообщение в «отдел невостребованных писем» вместе с причиной."""
    dlq_producer.produce(
        DLQ_TOPIC,
        key=msg.key(),
        value=msg.value(),
        headers={
            "error": reason,
            "source_topic": msg.topic(),
            "source_partition": str(msg.partition()),
            "source_offset": str(msg.offset()),
        },
    )
    dlq_producer.flush(10)
    print(f"  → DLQ: {reason}", flush=True)


def main():
    consumer.subscribe([TOPIC])
    print(f"Сервис уведомлений запущен, группа {GROUP}", flush=True)
    while True:
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            print(f"ошибка Kafka: {msg.error()}", flush=True)
            continue

        print(f"Получено: партиция {msg.partition()}, offset {msg.offset()}", flush=True)
        for attempt in range(1, MAX_ATTEMPTS + 1):
            try:
                handle(msg)
                break
            except PermanentError as exc:
                to_dlq(msg, str(exc))                      # повторы бессмысленны
                break
            except Exception as exc:                       # временная ошибка: шлюз, база
                if attempt == MAX_ATTEMPTS:
                    to_dlq(msg, f"не удалось за {MAX_ATTEMPTS} попытки: {exc}")
                    break
                pause = 2 ** (attempt - 1)
                print(f"  попытка {attempt} не удалась: {exc}; повтор через {pause} с", flush=True)
                time.sleep(pause)

        consumer.commit(message=msg, asynchronous=False)   # закладка — только после обработки


if __name__ == "__main__":
    main()