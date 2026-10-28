# Архитектура MVP «память ассистента»

Версия 0.3 · 28.10.2026

## 1. Схема

```
Telegram ⇄ бот-сервис (Python) ⇄ Postgres
                 │
                 ├─→ Ollama (разбор текста в задачу)
                 └─ планировщик (раз в минуту: наступившие напоминания → Telegram)
```

Всё запускается в docker compose.

## 2. Решения

| # | Решение | Почему | Минус / когда пересмотреть |
|---|---|---|---|
| Р-1 | Polling вместо webhook | Домашний компьютер не виден из интернета | При переезде на сервер можно перейти на webhook |
| Р-2 | Код на Python, не n8n | Статусы, черновики, переносы, тесты проще контролировать в коде | Больше кода |
| Р-3 | Ollama локально | Текст поручений не уходит наружу (риск «руководитель не разрешит») | Маленькая модель ошибается чаще → подтверждение (BR-08) и eval-набор |
| Р-4 | Планировщик устроен как outbox-relay | Запись в свою базу, потом доставка наружу; `FOR UPDATE SKIP LOCKED`; сбой → отправит при следующем проходе | См. «Доставка напоминаний» ниже |
| Р-5 | Два пояса: Europe/Paris для времени из сообщений, Europe/Moscow для времени ассистента | Даты в сообщениях названы руководителем (Париж), а удобно ассистенту получать напоминания по Москве | В базе UTC, в настройках — названия поясов, не смещения (BR-09) |
| Р-6 | Дату вычисляет код, а не модель | LLM плохо считает даты и может уверенно ошибиться | Модель возвращает поля `date`/`time`, код проверяет их по BR-03, BR-04, BR-06 |

### Доставка напоминаний (гарантия «хотя бы раз»)

Потерянное напоминание хуже дубля. Поэтому сначала отправляем в Telegram, потом пишем в `reminder_log`.
Если сервис упал между этими шагами, при следующем проходе напоминание уйдёт повторно: это допустимо.
`UNIQUE (task_id, remind_at, kind)` защищает от повторной отправки в обычной работе, а не от падения посреди операции.

### Часовые пояса

| Момент | Разница Париж − Москва |
|---|---|
| Зимнее время во Франции (конец октября — конец марта) | 2 часа |
| Летнее время во Франции (конец марта — конец октября) | 1 час |

Москва время не переводит, Франция переводит: поэтому смещение зашивать нельзя, только название пояса.

## 3. Модель данных

```sql
CREATE SCHEMA mate;

-- Пользователи бота (US-09: только из списка разрешённых)
CREATE TABLE mate.app_user (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    telegram_id   bigint NOT NULL UNIQUE,
    name          text   NOT NULL,
    timezone      text   NOT NULL DEFAULT 'Europe/Moscow',  -- BR-01: пояс ассистента (время по умолчанию, повторы)
    task_timezone text   NOT NULL DEFAULT 'Europe/Paris',   -- BR-01: пояс руководителя (время в сообщениях)
    is_allowed    boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Задачи
CREATE TABLE mate.task (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      bigint NOT NULL REFERENCES mate.app_user(id),
    title        text   NOT NULL,
    source_text  text   NOT NULL,              -- исходное сообщение (в логи не пишем!)
    status       text   NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'active', 'done')),   -- BR-08
    remind_at    timestamptz,                  -- хранится в UTC; NULL = дата ещё не указана (BR-06)
    parsed_by    text   NOT NULL DEFAULT 'llm'
                 CHECK (parsed_by IN ('llm', 'manual')),          -- US-08
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    done_at      timestamptz
);

-- Журнал отправленных напоминаний
CREATE TABLE mate.reminder_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id      bigint NOT NULL REFERENCES mate.task(id),
    remind_at    timestamptz NOT NULL,         -- на какое время было назначено
    kind         text NOT NULL CHECK (kind IN ('main', 'repeat')),
    sent_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (task_id, remind_at, kind)
);

CREATE INDEX task_due_idx ON mate.task (remind_at) WHERE status = 'active';
```

### Зачем `remind_at` в `reminder_log`

`task.remind_at` — текущий план, при переносе (US-06) он перезаписывается. Журнал помнит, на какие даты напоминания уже уходили.
После переноса на новую дату запись в журнале будет с другим `remind_at`, поэтому напоминание сработает снова.

Граничный случай: перенесли A → B → A. Напоминание на A уже есть в журнале, и `UNIQUE` его заблокирует.
Решение: при переносе добавлять в ключ номер версии плана или удалять запись журнала для невыполненной задачи. Решим при реализации US-06.

## 4. Открытые вопросы

См. раздел 4 в `backlog.md`.
