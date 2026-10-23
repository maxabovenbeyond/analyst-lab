# Матрица доступа «роль × эндпоинт»

Обозначения: ✅ — разрешено; ✅ свои — разрешено только для своих объектов (проверка по объекту);
❌ — запрещено (403); — — роль этот эндпоинт не вызывает.

| Эндпоинт | client | shop | support | Сервис (Client Credentials) | Проверка по объекту |
|---|---|---|---|---|---|
| GET /shops/{id}/products | ✅ | ✅ | ✅ | — | — (каталог публичный) |
| POST /orders | ✅ | ❌ | ❌ | — | — |
| GET /orders/{id} | ✅ свои | ✅ свои | ✅ | - | client: customer_id = sub; shop: shop_id из токена; чужой → 404 |
| GET /me/orders | ✅ | ❌ | ❌ | — | Только заказы sub |
| POST /orders/{id}/cancel | ✅ свои | ✅ свои | ✅ | — | client: customer_id = sub; shop: shop_id из токена; чужой → 404 |
| GET /shops/{id}/orders | ✅ свои | ✅ свои | ✅ | — | client: customer_id = sub; shop: shop_id из токена; чужой → 404 |
| POST /orders/{id}/accept | ❌ | ✅ свои | ✅ | — | shop: shop_id из токена; чужой → 404 |
| POST /claims/{id}/approve | ❌ | ❌ | ✅ | — | - |
| POST /webhooks/payments | — | — | — | — | Не OAuth: подпись HMAC |

## Как роль и принадлежность попадают в токен
- Роль: realm_access.roles (client / shop / support).
- client: sub из токена = id клиента.
- shop: id магазина — дополнительный claim `shop_id` (атрибут пользователя в Keycloak).