"""
Учебный сервис заказов. Реализует часть контракта 03-rest/openapi.yaml:
  GET  /v1/orders/{order_id}         — карточка заказа
  GET  /v1/shops/{shop_id}/orders    — заказы магазина (cursor-пагинация)
  POST /v1/orders/{order_id}/cancel  — отмена заказа
"""
import hashlib
import hmac
from decimal import Decimal

from psycopg.types.json import Jsonb
from pydantic import ValidationError

import base64
import json
import os
from datetime import datetime
from typing import Literal, Optional

import psycopg
from psycopg.rows import dict_row
from fastapi import APIRouter, FastAPI, Header, Query, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# Адрес базы берём из настроек контейнера (docker-compose.yml → environment)
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://lab:lab@localhost:5432/lab")

# Аналог enum OrderStatus из контракта: другие значения FastAPI не пропустит
OrderStatus = Literal[
    "AWAITING_PAYMENT", "PAID", "ASSEMBLING", "AWAITING_COURIER",
    "IN_DELIVERY", "DELIVERED", "CANCELLED",
]

app = FastAPI(title="Сервис доставки — реализация API", version="0.1.0")

# CORS: разрешаем странице Swagger UI (порт 8082) обращаться к нашему API (порт 8000)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8082"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Все эндпоинты API начинаются с /v1 — как servers.url в контракте
router = APIRouter(prefix="/v1")


# =====================================================================
# 1. ОШИБКИ В ФОРМАТЕ RFC 9457 (components/responses в контракте)
# =====================================================================

class ApiError(Exception):
    """Бизнес-ошибка: бросаем её в любом месте, ответ оформит обработчик ниже."""
    def __init__(self, status: int, title: str, detail: str):
        self.status, self.title, self.detail = status, title, detail


def problem(request: Request, status: int, title: str, detail: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        media_type="application/problem+json",
        content={
            "type": "about:blank",
            "title": title,
            "status": status,
            "detail": detail,
            "instance": request.url.path,
        },
    )


@app.exception_handler(ApiError)
async def handle_api_error(request: Request, exc: ApiError):
    return problem(request, exc.status, exc.title, exc.detail)


@app.exception_handler(RequestValidationError)
async def handle_validation_error(request: Request, exc: RequestValidationError):
    """
    Ошибки контролёра бланков (Pydantic). По умолчанию FastAPI на всё отвечает 422,
    а по нашему контракту:
      - битый JSON или неверные параметры пути/query → 400
      - тело понятно, но нарушает правила (reason короче 3 символов) → 422
    """
    errors = exc.errors()
    detail = "; ".join(
        f"{'.'.join(str(part) for part in e['loc'])}: {e['msg']}" for e in errors
    )
    broken_json = any(e["type"] == "json_invalid" for e in errors)
    in_body = any(e["loc"] and e["loc"][0] == "body" for e in errors)
    if in_body and not broken_json:
        return problem(request, 422, "Ошибка валидации", detail)
    return problem(request, 400, "Некорректный запрос", detail)


# =====================================================================
# 2. АВТОРИЗАЦИЯ (securitySchemes: bearerAuth)
# =====================================================================

def current_user(authorization: Optional[str]) -> dict:
    """
    Учебная авторизация. Токены: 'support', 'shop-<id>', 'customer-<id>'.
    В реальной системе здесь проверялась бы подпись JWT, а роль и id брались бы из него.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise ApiError(401, "Требуется авторизация",
                       "Передайте заголовок Authorization: Bearer <токен>")
    token = authorization.removeprefix("Bearer ").strip()
    if token == "support":
        return {"role": "SUPPORT", "id": None}
    role, _, ident = token.partition("-")
    if role in ("shop", "customer") and ident.isdigit():
        return {"role": role.upper(), "id": int(ident)}
    raise ApiError(401, "Неверный токен", "Токен не распознан")


def can_see(user: dict, order: dict) -> bool:
    """Кто какой заказ видит: поддержка — все, магазин — свои, клиент — свои."""
    if user["role"] == "SUPPORT":
        return True
    if user["role"] == "SHOP":
        return order["shop_id"] == user["id"]
    return order["customer_id"] == user["id"]


# =====================================================================
# 3. РАБОТА С БАЗОЙ
# =====================================================================

def db():
    """Подключение к базе. Блок `with db() as conn:` — это одна транзакция:
    в конце блока COMMIT, а если внутри возникла ошибка — ROLLBACK."""
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


# Если в вашей таблице колонки называются иначе — поправьте здесь и в load_items
ORDER_COLUMNS = ("id, shop_id, customer_id, status, items_amount, "
                 "delivery_fee, cancel_reason, created_at")


def load_order(conn, order_id: int, for_update: bool = False):
    sql = f"SELECT {ORDER_COLUMNS} FROM delivery.orders WHERE id = %s"
    if for_update:
        sql += " FOR UPDATE"   # блокировка строки, как в эксперименте из модуля 2
    return conn.execute(sql, (order_id,)).fetchone()


def load_items(conn, order_id: int):
    return conn.execute(
        """
        SELECT oi.product_id, p.name, oi.price, oi.quantity
        FROM delivery.order_item oi
        JOIN delivery.product p ON p.id = oi.product_id
        WHERE oi.order_id = %s
        ORDER BY oi.product_id
        """,
        (order_id,),
    ).fetchall()


def order_out(order: dict, items=None) -> dict:
    """Превращаем строку БД в объект Order из контракта.
    customer_id наружу не отдаём: в схеме Order его нет."""
    data = {k: order[k] for k in (
        "id", "shop_id", "status", "items_amount",
        "delivery_fee", "cancel_reason", "created_at",
    )}
    if items is not None:
        data["items"] = items
    return jsonable_encoder(data)   # numeric → число, timestamptz → строка ISO 8601


# =====================================================================
# 4. ЭНДПОИНТЫ
# =====================================================================

# ---------- GET /v1/orders/{order_id} (operationId: getOrder) ----------
@router.get("/orders/{order_id}")
def get_order(order_id: int, authorization: Optional[str] = Header(None)):
    user = current_user(authorization)                       # → 401
    with db() as conn:
        order = load_order(conn, order_id)
        if order is None or not can_see(user, order):
            # чужой заказ — тоже 404: скрываем факт существования
            raise ApiError(404, "Заказ не найден", f"Заказ {order_id} не найден")
        return order_out(order, load_items(conn, order_id))  # → 200


# ---------- GET /v1/shops/{shop_id}/orders (operationId: listShopOrders) ----------

def encode_cursor(row: dict) -> str:
    """Закладка = created_at и id последней записи страницы, упакованные в base64."""
    raw = json.dumps({"created_at": row["created_at"].isoformat(), "id": row["id"]})
    return base64.urlsafe_b64encode(raw.encode()).decode()


def decode_cursor(cursor: str):
    try:
        data = json.loads(base64.urlsafe_b64decode(cursor.encode()))
        return datetime.fromisoformat(data["created_at"]), int(data["id"])
    except Exception:
        raise ApiError(400, "Некорректный курсор",
                       "Передайте значение next_cursor из предыдущего ответа без изменений")


@router.get("/shops/{shop_id}/orders")
def list_shop_orders(
    shop_id: int,
    status: Optional[OrderStatus] = None,                  # не из списка → 400
    created_from: Optional[datetime] = None,               # не дата → 400
    limit: int = Query(50, ge=1, le=100),                  # вне 1..100 → 400
    cursor: Optional[str] = None,
    authorization: Optional[str] = Header(None),
):
    user = current_user(authorization)                     # → 401
    if not (user["role"] == "SUPPORT"
            or (user["role"] == "SHOP" and user["id"] == shop_id)):
        # магазины не секрет, поэтому честно 403, а не 404
        raise ApiError(403, "Нет доступа", f"Нет прав на заказы магазина {shop_id}")

    # Собираем WHERE из фильтров. Значения передаются через %s, а не вклеиваются
    # в текст запроса — это защита от SQL-инъекций.
    where, params = ["shop_id = %s"], [shop_id]
    if status:
        where.append("status = %s")
        params.append(status)
    if created_from:
        where.append("created_at >= %s")
        params.append(created_from)
    if cursor:
        cursor_at, cursor_id = decode_cursor(cursor)
        where.append("(created_at, id) < (%s, %s)")        # keyset: всё «после закладки»
        params += [cursor_at, cursor_id]

    sql = (f"SELECT {ORDER_COLUMNS} FROM delivery.orders "
           f"WHERE {' AND '.join(where)} "
           "ORDER BY created_at DESC, id DESC LIMIT %s")
    params.append(limit + 1)   # берём на одну запись больше, чтобы понять, есть ли следующая страница

    with db() as conn:
        rows = conn.execute(sql, params).fetchall()

    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "items": [order_out(r) for r in rows],
        "next_cursor": encode_cursor(rows[-1]) if has_more else None,
    }                                                      # → 200


# ---------- POST /v1/orders/{order_id}/cancel (operationId: cancelOrder) ----------

class CancelRequest(BaseModel):
    """Схема CancelRequest из контракта: required + minLength/maxLength."""
    reason: str = Field(min_length=3, max_length=200)


# Матрица переходов для отмены: кто из каких статусов может отменить
CANCEL_ALLOWED_FROM = {
    "CUSTOMER": {"AWAITING_PAYMENT", "PAID"},
    "SUPPORT": {"AWAITING_PAYMENT", "PAID", "ASSEMBLING", "AWAITING_COURIER"},
}


@router.post("/orders/{order_id}/cancel")
def cancel_order(order_id: int, body: CancelRequest,       # нет reason → 422
                 authorization: Optional[str] = Header(None)):
    user = current_user(authorization)                     # → 401
    if user["role"] not in CANCEL_ALLOWED_FROM:
        raise ApiError(403, "Нет доступа",
                       "Магазин отказывается от заказа командой decline, а не cancel")

    with db() as conn:                                     # одна транзакция
        order = load_order(conn, order_id, for_update=True)  # блокируем строку
        if order is None or not can_see(user, order):
            raise ApiError(404, "Заказ не найден", f"Заказ {order_id} не найден")

        if order["status"] == "CANCELLED":
            # повторный вызов: цель уже достигнута → 200 без изменений
            return order_out(order, load_items(conn, order_id))

        if order["status"] not in CANCEL_ALLOWED_FROM[user["role"]]:
            raise ApiError(409, "Недопустимый переход статуса",
                           f"Заказ {order_id} в статусе {order['status']} нельзя отменить")

        conn.execute(
            "UPDATE delivery.orders SET status = 'CANCELLED', cancel_reason = %s WHERE id = %s",
            (body.reason, order_id),
        )
        conn.execute(
            """INSERT INTO delivery.order_status_history (order_id, status, changed_at, changed_by)
               VALUES (%s, 'CANCELLED', now(), %s)""",
            (order_id, user["role"]),
        )
        # TODO шаг 4: если заказ был оплачен — инициировать возврат через провайдера
        order = load_order(conn, order_id)
        return order_out(order, load_items(conn, order_id))  # → 200, COMMIT

# =====================================================================
# 5. ВЕБХУК ПЛАТЁЖНОГО ПРОВАЙДЕРА (operationId: paymentWebhook)
# =====================================================================

# Общий секрет с провайдером. Берётся из настроек контейнера, в коде не хранится.
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "lab-secret")

# Комиссия провайдера, как в seed.sql
PROVIDER_FEE_RATE = Decimal("0.025")


class PaymentEvent(BaseModel):
    """Схема PaymentEvent из контракта."""
    event_id: str = Field(min_length=1)
    type: Literal["payment.succeeded", "payment.declined", "refund.succeeded"]
    provider_payment_id: str = Field(min_length=1)
    order_id: int
    amount: Decimal = Field(gt=0)
    occurred_at: datetime


def verify_signature(raw_body: bytes, signature: Optional[str]) -> None:
    """Сургучная печать: HMAC-SHA256 от тела запроса на общем секрете."""
    expected = hmac.new(WEBHOOK_SECRET.encode(), raw_body, hashlib.sha256).hexdigest()
    # compare_digest сравнивает за одинаковое время — защита от подбора подписи по времени ответа
    if not signature or not hmac.compare_digest(expected, signature):
        raise ApiError(401, "Неверная подпись", "Подпись X-Signature не совпала с телом запроса")


def money(value) -> Decimal:
    return Decimal(value).quantize(Decimal("0.01"))


def process_payment_event(conn, e: PaymentEvent) -> str:
    """Бизнес-логика: что сделать с событием. Возвращает итог для журнала."""
    order = load_order(conn, e.order_id, for_update=True)
    if order is None:
        raise ApiError(404, "Заказ не найден", f"Заказ {e.order_id} не найден")

    if e.type == "refund.succeeded":
        return "IGNORED_REFUNDS_NOT_IMPLEMENTED"       # возвраты сделаем позже

    status = "SUCCEEDED" if e.type == "payment.succeeded" else "DECLINED"

    if status == "SUCCEEDED":
        expected = money(order["items_amount"] + order["delivery_fee"])
        if money(e.amount) != expected:
            raise ApiError(422, "Сумма не совпадает",
                           f"Заказ {e.order_id}: ожидалось {expected}, пришло {money(e.amount)}")

    fee = money(e.amount * PROVIDER_FEE_RATE) if status == "SUCCEEDED" else Decimal("0")

    # Второй рубеж: UNIQUE(provider_payment_id). Тот же платёж в новом событии не запишется дважды.
    inserted = conn.execute(
        """
        INSERT INTO delivery.payment
            (order_id, type, status, amount, fee, provider_payment_id, created_at)
        VALUES (%s, 'PAYMENT', %s, %s, %s, %s, %s)
        ON CONFLICT (provider_payment_id) DO NOTHING
        RETURNING id
        """,
        (e.order_id, status, money(e.amount), fee, e.provider_payment_id, e.occurred_at),
    ).fetchone()

    if inserted is None:
        return "PAYMENT_ALREADY_RECORDED"
    if status == "DECLINED":
        return "DECLINED_RECORDED"                     # заказ остаётся AWAITING_PAYMENT

    if order["status"] == "AWAITING_PAYMENT":
        conn.execute("UPDATE delivery.orders SET status = 'PAID' WHERE id = %s", (e.order_id,))
        conn.execute(
            """INSERT INTO delivery.order_status_history (order_id, status, changed_at, changed_by)
               VALUES (%s, 'PAID', now(), 'PAYMENT_PROVIDER')""",
            (e.order_id,),
        )
        return "ORDER_PAID"

    if order["status"] == "CANCELLED":
        # Деньги пришли после отмены: платёж записали, статус не трогаем, нужен возврат
        return "PAID_AFTER_CANCEL_REFUND_NEEDED"

    return f"PAYMENT_RECORDED_ORDER_IS_{order['status']}"


@router.post("/webhooks/payments")
async def payment_webhook(request: Request, x_signature: Optional[str] = Header(None)):
    raw_body = await request.body()        # подпись считается от сырых байтов, а не от разобранного JSON

    verify_signature(raw_body, x_signature)                                  # 1. печать → 401

    try:
        event = PaymentEvent.model_validate_json(raw_body)                    # 2. формат → 400
    except ValidationError as exc:
        raise ApiError(400, "Некорректное событие",
                       "; ".join(f"{'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors()))

    with db() as conn:                                                        # шаги 3–7: одна транзакция
        # 3. Журнал входящих: первый раз видим это событие?
        first_time = conn.execute(
            """
            INSERT INTO delivery.webhook_event (event_id, provider, event_type, payload, result)
            VALUES (%s, 'PAYMENT', %s, %s, 'PROCESSING')
            ON CONFLICT (event_id) DO NOTHING
            RETURNING event_id
            """,
            (event.event_id, event.type, Jsonb(json.loads(raw_body))),
        ).fetchone()
        if first_time is None:
            return {"result": "DUPLICATE"}                                   # копия → 200

        result = process_payment_event(conn, event)                           # 4–7
        conn.execute("UPDATE delivery.webhook_event SET result = %s WHERE event_id = %s",
                     (result, event.event_id))
        return {"result": result}                                            # → 200, COMMIT

# ---------- служебный эндпоинт: жив ли сервис и видит ли он базу ----------
@app.get("/health")
def health():
    with db() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


app.include_router(router)