-- Проверки качества данных. Каждый запрос должен вернуть 0 строк
SET search_path TO delivery;

-- 1. Сумма позиций совпадает с items_amount
SELECT o.id, o.items_amount, round(sum(oi.quantity * oi.price), 2) AS items_sum
FROM orders o
JOIN order_item oi ON oi.order_id = o.id
GROUP BY o.id, o.items_amount
HAVING o.items_amount <> round(sum(oi.quantity * oi.price), 2);

-- 1а. Нет заказов без позиций (первая проверка их не увидит: JOIN их отбросит)
SELECT o.id
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM order_item oi WHERE oi.order_id = o.id);

-- 2. Отменённый заказ ⇔ есть строка CANCELLED в истории (в обе стороны)
SELECT o.id, o.status, h.order_id IS NOT NULL AS has_cancel_row
FROM orders o
LEFT JOIN order_status_history h ON h.order_id = o.id AND h.status = 'CANCELLED'
WHERE (o.status = 'CANCELLED') <> (h.order_id IS NOT NULL);

-- 3. У доставленного заказа ровно один успешный платёж и хотя бы одна успешная доставка.
--    Считаем через LATERAL, а не через два LEFT JOIN: иначе платежи × доставки
--    размножат строки и count() покажет неверные числа
SELECT o.id, pay.cnt AS payments, dlv.cnt AS deliveries
FROM orders o
CROSS JOIN LATERAL (
    SELECT count(*) AS cnt FROM payment p
    WHERE p.order_id = o.id AND p.type = 'PAYMENT' AND p.status = 'SUCCEEDED'
) pay
CROSS JOIN LATERAL (
    SELECT count(*) AS cnt FROM delivery d
    WHERE d.order_id = o.id AND d.status = 'DELIVERED'
) dlv
WHERE o.status = 'DELIVERED'
  AND (pay.cnt <> 1 OR dlv.cnt = 0);

-- 4. Время в истории растёт в порядке жизненного цикла заказа.
--    Сортируем по бизнес-порядку статусов, а не по времени: иначе проверка
--    всегда «проходила» бы — отсортированное по времени всегда идёт по возрастанию
SELECT order_id, status, changed_at, prev_status, prev_at
FROM (
    SELECT order_id, status, changed_at,
           lag(status)     OVER w AS prev_status,
           lag(changed_at) OVER w AS prev_at
    FROM order_status_history
    WINDOW w AS (
        PARTITION BY order_id
        ORDER BY array_position(
            ARRAY['AWAITING_PAYMENT', 'PAID', 'ASSEMBLING', 'AWAITING_COURIER',
                  'IN_DELIVERY', 'DELIVERED', 'CANCELLED']::varchar[], status)
    )
) t
WHERE changed_at < prev_at;

-- 5. Последний статус в истории совпадает с текущим статусом заказа
--    (LEFT JOIN + IS DISTINCT FROM ловит и заказы совсем без истории)
SELECT o.id, o.status, h.status AS last_history_status
FROM orders o
LEFT JOIN LATERAL (
    SELECT status FROM order_status_history h
    WHERE h.order_id = o.id
    ORDER BY changed_at DESC, id DESC
    LIMIT 1
) h ON true
WHERE h.status IS DISTINCT FROM o.status;

-- 6. У каждой одобренной претензии есть возврат на ту же сумму
--    (запускать после seed-claims.sql)
SELECT c.id, c.refund_amount, p.amount AS refunded
FROM claim c
LEFT JOIN payment p ON p.provider_payment_id = 'CLM-' || c.id
WHERE c.status = 'APPROVED'
  AND (p.id IS NULL OR p.amount <> c.refund_amount);