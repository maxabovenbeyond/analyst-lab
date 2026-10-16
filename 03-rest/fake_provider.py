"""
Фальшивый платёжный провайдер: отправляет вебхук так же, как настоящий.
- подписывает тело HMAC-SHA256 на общем секрете;
- если ответ не 2xx, повторяет с паузами 1, 2, 4... секунды (at-least-once).

Примеры:
  python3 03-rest/fake_provider.py --order 123 --amount 2547.00
  python3 03-rest/fake_provider.py --order 123 --amount 2547.00 --times 3
  python3 03-rest/fake_provider.py --order 123 --amount 2547.00 --bad-signature
"""
import argparse
import hashlib
import hmac
import json
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

URL = "http://localhost:8000/v1/webhooks/payments"
SECRET = "lab-secret"


def send(body: bytes, signature: str):
    request = urllib.request.Request(
        URL, data=body, method="POST",
        headers={"Content-Type": "application/json", "X-Signature": signature},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except urllib.error.URLError as error:
        return None, f"нет соединения: {error.reason}"


def deliver(body: bytes, signature: str, retries: int):
    """Доставка с повторами, как у настоящего провайдера."""
    for attempt in range(1, retries + 1):
        code, text = send(body, signature)
        print(f"  попытка {attempt}: {code} {text}")
        if code is not None and 200 <= code < 300:
            return
        if attempt < retries:
            pause = 2 ** (attempt - 1)
            print(f"  не 2xx → повтор через {pause} с")
            time.sleep(pause)
    print("  доставка не удалась, провайдер сдаётся (в жизни — алерт и ручной разбор)")


def main():
    p = argparse.ArgumentParser(description="Фальшивый платёжный провайдер")
    p.add_argument("--order", type=int, required=True, help="id заказа")
    p.add_argument("--amount", type=float, required=True, help="сумма платежа")
    p.add_argument("--type", default="payment.succeeded",
                   choices=["payment.succeeded", "payment.declined", "refund.succeeded"])
    p.add_argument("--event-id", help="id события (по умолчанию новый)")
    p.add_argument("--payment-id", help="id платежа у провайдера (по умолчанию PAY-TEST-<order>)")
    p.add_argument("--times", type=int, default=1, help="сколько раз отправить ОДНО И ТО ЖЕ событие")
    p.add_argument("--retries", type=int, default=3, help="число попыток при ответе не 2xx")
    p.add_argument("--bad-signature", action="store_true", help="испортить подпись")
    a = p.parse_args()

    event = {
        "event_id": a.event_id or f"evt_{uuid.uuid4().hex[:10]}",
        "type": a.type,
        "provider_payment_id": a.payment_id or f"PAY-TEST-{a.order}",
        "order_id": a.order,
        "amount": a.amount,
        "occurred_at": datetime.now(timezone.utc).isoformat(),
    }
    body = json.dumps(event, ensure_ascii=False).encode()
    signature = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    if a.bad_signature:
        signature = "0" * 64

    print(f"Событие: {body.decode()}")
    print(f"Подпись: {signature[:16]}...")
    for n in range(1, a.times + 1):
        print(f"Отправка {n} из {a.times}:")
        deliver(body, signature, a.retries)


if __name__ == "__main__":
    main()