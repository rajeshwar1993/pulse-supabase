-- FCM device tokens for push notifications
-- Each row = one device registered for push notifications

CREATE TABLE fcm_tokens (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  token       TEXT        NOT NULL UNIQUE,
  device_type TEXT        NOT NULL CHECK (device_type IN ('ios', 'android', 'web')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fcm_tokens_user_id ON fcm_tokens(user_id);

ALTER TABLE fcm_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY fcm_tokens_select_own ON fcm_tokens FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY fcm_tokens_insert_own ON fcm_tokens FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY fcm_tokens_update_own ON fcm_tokens FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY fcm_tokens_delete_own ON fcm_tokens FOR DELETE
  USING (auth.uid() = user_id);

CREATE TRIGGER update_fcm_tokens_updated_at
  BEFORE UPDATE ON fcm_tokens
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();
