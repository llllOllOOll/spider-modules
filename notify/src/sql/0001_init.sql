-- spider_notify 0001_init: the module's tables. Applied by `spider migrate`
-- (server.migrateModules) in a transaction Spider opens, recorded as
-- notify/0001_init with its checksum. Never edit it once released: add
-- 0002_... instead. PostgreSQL 13 or newer (gen_random_uuid).

-- One row per notification: the content, shared by all its deliveries.
CREATE TABLE IF NOT EXISTS notify_messages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- What the app calls this kind of notification: "ai.quota_95".
  kind       text NOT NULL CHECK (kind ~ '^[a-z0-9_.-]{1,64}$'),
  -- The app's partition (a tenant, an organization), or NULL.
  scope      text CHECK (length(scope) BETWEEN 1 AND 64),
  title      text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  body       text NOT NULL DEFAULT '' CHECK (length(body) <= 2000),
  url        text NOT NULL DEFAULT '' CHECK (length(url) <= 1000),
  icon       text NOT NULL DEFAULT '' CHECK (length(icon) <= 64),
  data       jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- At most one notification per key: a second send with it records nothing.
  dedup_key  text UNIQUE CHECK (length(dedup_key) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notify_messages_scope_idx ON notify_messages (scope, created_at DESC);

-- One row per (notification, recipient, channel).
CREATE TABLE IF NOT EXISTS notify_deliveries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id        uuid NOT NULL REFERENCES notify_messages(id) ON DELETE CASCADE,
  -- A user of the app (its own id, as text), or a bare address.
  recipient_user    text CHECK (length(recipient_user) BETWEEN 1 AND 64),
  recipient_address text CHECK (length(recipient_address) BETWEEN 1 AND 320),
  channel           text NOT NULL CHECK (channel ~ '^[a-z0-9_]{1,32}$'),
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'skipped', 'expired')),
  attempts          integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at   timestamptz NOT NULL DEFAULT now(),
  -- While `sending`: until when the worker that claimed it owns it.
  lease_until       timestamptz,
  last_error        text CHECK (length(last_error) <= 300),
  delivered_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK ((recipient_user IS NULL) <> (recipient_address IS NULL)),
  CHECK ((status = 'sending') = (lease_until IS NOT NULL))
);

-- The worker's two questions: what is due on a channel, and whose lease ran out.
CREATE INDEX IF NOT EXISTS notify_deliveries_due_idx
  ON notify_deliveries (channel, next_attempt_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS notify_deliveries_leased_idx
  ON notify_deliveries (lease_until) WHERE status = 'sending';
CREATE INDEX IF NOT EXISTS notify_deliveries_message_idx ON notify_deliveries (message_id);
CREATE INDEX IF NOT EXISTS notify_deliveries_user_idx
  ON notify_deliveries (recipient_user, created_at DESC) WHERE recipient_user IS NOT NULL;

-- The default in-app inbox (the `inbox` channel).
CREATE TABLE IF NOT EXISTS notify_inbox (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    text NOT NULL CHECK (length(user_id) BETWEEN 1 AND 64),
  message_id uuid NOT NULL REFERENCES notify_messages(id) ON DELETE CASCADE,
  read_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, message_id)
);

CREATE INDEX IF NOT EXISTS notify_inbox_user_idx ON notify_inbox (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notify_inbox_unread_idx ON notify_inbox (user_id) WHERE read_at IS NULL;

-- The default address book: where each channel reaches each user.
CREATE TABLE IF NOT EXISTS notify_addresses (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      text NOT NULL CHECK (length(user_id) BETWEEN 1 AND 64),
  channel      text NOT NULL CHECK (channel ~ '^[a-z0-9_]{1,32}$'),
  -- A push subscription (JSON), an FCM token, a phone, an email address.
  value        text NOT NULL CHECK (length(value) BETWEEN 1 AND 4000),
  label        text NOT NULL DEFAULT '' CHECK (length(label) <= 120),
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  UNIQUE (channel, value)
);

CREATE INDEX IF NOT EXISTS notify_addresses_user_idx ON notify_addresses (user_id, channel);
