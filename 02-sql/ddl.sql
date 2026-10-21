-- DDL: Сервис доставки из локальных магазинов
-- Повторный запуск пересоздаёт схему с нуля

DROP SCHEMA IF EXISTS delivery CASCADE;
CREATE SCHEMA delivery;
SET search_path TO delivery;

-- Клиент
CREATE TABLE customer (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone         varchar(20)  NOT NULL UNIQUE,
    name          varchar(100),
    pd_consent_at timestamptz  NOT NULL,                        -- NFR-05: согласие на обработку ПД
    created_at    timestamptz  NOT NULL DEFAULT now()
);

-- Магазин
CREATE TABLE shop (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name               varchar(200) NOT NULL,
    address            varchar(300) NOT NULL,
    commission_percent numeric(4,2) NOT NULL
        CHECK (commission_percent >= 0 AND commission_percent <= 15),  -- Vision: комиссия до 15 %
    is_active          boolean      NOT NULL DEFAULT true,
    created_at         timestamptz  NOT NULL DEFAULT now()
);

-- Заказ
CREATE TABLE orders (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      bigint        NOT NULL REFERENCES customer(id),
    shop_id          bigint        NOT NULL REFERENCES shop(id),
    status           varchar(30)   NOT NULL DEFAULT 'AWAITING_PAYMENT'
        CHECK (status IN ('AWAITING_PAYMENT', 'PAID', 'ASSEMBLING', 'AWAITING_COURIER',
                          'IN_DELIVERY', 'DELIVERED', 'CANCELLED')),        -- state-диаграмма
    items_amount     numeric(10,2) NOT NULL CHECK (items_amount >= 0),
    delivery_fee     numeric(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    delivery_address varchar(300)  NOT NULL,
    cancel_reason    varchar(100),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    -- Причина отмены есть только у отменённых заказов, и у каждого отменённого она есть
    CONSTRAINT chk_cancel_reason CHECK ((status = 'CANCELLED') = (cancel_reason IS NOT NULL))
);

-- Сотрудник магазина
CREATE TABLE shop_user (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shop_id bigint      NOT NULL REFERENCES shop(id),
    phone   varchar(20) NOT NULL UNIQUE,
    role    varchar(20) NOT NULL DEFAULT 'STAFF'
        CHECK (role IN ('STAFF', 'OWNER'))
);

-- Товар
CREATE TABLE product (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shop_id  bigint        NOT NULL REFERENCES shop(id),
    name     varchar(200)  NOT NULL,
    price    numeric(10,2) NOT NULL CHECK (price > 0),          -- US-11: цена больше нуля
    unit     varchar(20)   NOT NULL DEFAULT 'шт'
        CHECK (unit IN ('шт', 'кг', 'л')),
    in_stock boolean       NOT NULL DEFAULT true                -- US-14: актуальное наличие
);

-- Оператор поддержки
CREATE TABLE support_user (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name  varchar(100) NOT NULL,
    email varchar(100) NOT NULL UNIQUE
);

-- Позиция заказа
CREATE TABLE order_item (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   bigint        NOT NULL REFERENCES orders(id),
    product_id bigint        NOT NULL REFERENCES product(id),
    quantity   numeric(10,3) NOT NULL CHECK (quantity > 0),
    price      numeric(10,2) NOT NULL CHECK (price >= 0),       -- цена на момент заказа
    CONSTRAINT uq_order_product UNIQUE (order_id, product_id)   -- товар не повторяется в заказе
);

-- Платёж
CREATE TABLE payment (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            bigint        NOT NULL REFERENCES orders(id),  -- у заказа может быть несколько платежей
    type                varchar(10)   NOT NULL DEFAULT 'PAYMENT'
        CHECK (type IN ('PAYMENT', 'REFUND')),
    status              varchar(20)   NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'SUCCEEDED', 'DECLINED')),
    amount              numeric(10,2) NOT NULL CHECK (amount > 0),
    provider_payment_id varchar(100)  NOT NULL UNIQUE,          -- US-15: защита от дублей
    decline_reason      varchar(200),
    fee                 numeric(10,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),  -- трассировка: маржа
    created_at          timestamptz   NOT NULL DEFAULT now()
);

-- Доставка
CREATE TABLE delivery (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id             bigint        NOT NULL REFERENCES orders(id),
    provider             varchar(10)   NOT NULL DEFAULT 'MAIN'
        CHECK (provider IN ('MAIN', 'BACKUP')),
    provider_delivery_id varchar(100)  NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'REQUESTED'
        CHECK (status IN ('REQUESTED', 'ASSIGNED', 'PICKED_UP', 'DELIVERED', 'FAILED', 'CANCELLED')),
    courier_name         varchar(100),
    cost                 numeric(10,2) NOT NULL DEFAULT 0 CHECK (cost >= 0),  -- трассировка: маржа
    created_at           timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT uq_provider_delivery UNIQUE (provider, provider_delivery_id)
);

-- Претензия
CREATE TABLE claim (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        bigint        NOT NULL REFERENCES orders(id),
    order_item_id   bigint        REFERENCES order_item(id),    -- null: претензия на весь заказ
    support_user_id bigint        REFERENCES support_user(id),  -- null: оператор не назначен
    status          varchar(20)   NOT NULL DEFAULT 'OPEN'
        CHECK (status IN ('OPEN', 'APPROVED', 'REJECTED')),
    reason          varchar(500)  NOT NULL,
    photo_urls      text[],
    refund_amount   numeric(10,2) CHECK (refund_amount > 0),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    resolved_at     timestamptz,
    -- Дата решения есть только у закрытых претензий
    CONSTRAINT chk_resolved_at CHECK ((status <> 'OPEN') = (resolved_at IS NOT NULL))
);

-- История статусов заказа
CREATE TABLE order_status_history (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   bigint      NOT NULL REFERENCES orders(id),
    status     varchar(30) NOT NULL
        CHECK (status IN ('AWAITING_PAYMENT', 'PAID', 'ASSEMBLING', 'AWAITING_COURIER',
                          'IN_DELIVERY', 'DELIVERED', 'CANCELLED')),
    changed_at timestamptz NOT NULL DEFAULT now(),
    changed_by varchar(20) NOT NULL                             -- без значения по умолчанию: всегда явно
        CHECK (changed_by IN ('CUSTOMER', 'SHOP', 'SUPPORT', 'SYSTEM',
                              'PAYMENT_PROVIDER', 'DELIVERY_PROVIDER'))
);


-- ===== Индексы =====
-- PostgreSQL не создаёт индексы для внешних ключей автоматически
CREATE INDEX idx_orders_customer        ON orders (customer_id);
CREATE INDEX idx_orders_shop_created    ON orders (shop_id, created_at);   -- заказы магазина за период (кабинет, метрики)
CREATE INDEX idx_orders_status_created  ON orders (status, created_at);    -- кабинет магазина: новые оплаченные заказы
CREATE INDEX idx_product_shop           ON product (shop_id);
CREATE INDEX idx_order_item_product     ON order_item (product_id);
-- order_item (order_id) не нужен: его покрывает UNIQUE (order_id, product_id) — order_id стоит первым
CREATE INDEX idx_payment_order          ON payment (order_id);
CREATE INDEX idx_delivery_order         ON delivery (order_id);
CREATE INDEX idx_claim_order            ON claim (order_id);
CREATE INDEX idx_history_order_changed  ON order_status_history (order_id, changed_at);  -- история заказа для поддержки

-- Журнал входящих вебхуков: защита от повторной обработки (at-least-once)
CREATE TABLE delivery.webhook_event (
    event_id     text        PRIMARY KEY,
    provider     text        NOT NULL CHECK (provider IN ('PAYMENT', 'DELIVERY')),
    event_type   text        NOT NULL,
    payload      jsonb       NOT NULL,
    result       text        NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now()
);

-- Transactional Outbox: события, ожидающие публикации в Kafka
CREATE TABLE delivery.outbox (
    id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id      uuid        NOT NULL UNIQUE,
    aggregate_id  text        NOT NULL,   -- ключ сообщения в Kafka (order_id)
    event_type    text        NOT NULL,
    event         jsonb       NOT NULL,   -- событие целиком: конверт + payload
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz             -- NULL = ещё не отправлено
);

-- Частичный индекс: только по неотправленным. Relay ищет именно их.
CREATE INDEX idx_outbox_unpublished ON delivery.outbox (id) WHERE published_at IS NULL;