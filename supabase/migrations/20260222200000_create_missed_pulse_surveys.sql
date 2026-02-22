-- Missed Pulse Surveys (PRD 5.2)
-- Records why a user missed a pulse day. Shown once per missed day, never re-prompted.

CREATE TABLE missed_pulse_surveys (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  missed_date DATE       NOT NULL,
  response   TEXT        NOT NULL CHECK (response IN ('forgot', 'busy', 'tech_issue', 'not_feeling_it', 'skipped')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(user_id, missed_date)
);

CREATE INDEX idx_missed_pulse_surveys_user_date
  ON missed_pulse_surveys (user_id, missed_date DESC);

-- RLS: users can only read and insert their own rows (responses are immutable)
ALTER TABLE missed_pulse_surveys ENABLE ROW LEVEL SECURITY;

CREATE POLICY missed_pulse_surveys_select_own
  ON missed_pulse_surveys FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY missed_pulse_surveys_insert_own
  ON missed_pulse_surveys FOR INSERT
  WITH CHECK (auth.uid() = user_id);
