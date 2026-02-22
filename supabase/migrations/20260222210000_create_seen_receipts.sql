-- Seen Receipts (PRD 2.2)
-- Records when a user sees another user's pulse status on the dashboard.
-- One receipt per (viewer, viewed_user, pulse_day) via UNIQUE constraint.

CREATE TABLE seen_receipts (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  viewer_id        UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  viewed_user_id   UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  pulse_date       DATE        NOT NULL,
  seen_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  notification_sent_at TIMESTAMPTZ,

  UNIQUE(viewer_id, viewed_user_id, pulse_date),
  CHECK (viewer_id != viewed_user_id)
);

CREATE INDEX idx_seen_receipts_viewer_date
  ON seen_receipts (viewer_id, pulse_date DESC);

CREATE INDEX idx_seen_receipts_viewed_date
  ON seen_receipts (viewed_user_id, pulse_date DESC);

-- RLS: immutable records (SELECT + INSERT only)
ALTER TABLE seen_receipts ENABLE ROW LEVEL SECURITY;

-- Viewer can see their own sent receipts
CREATE POLICY seen_receipts_select_viewer
  ON seen_receipts FOR SELECT
  USING (auth.uid() = viewer_id);

-- Viewed user can see who saw them
CREATE POLICY seen_receipts_select_viewed
  ON seen_receipts FOR SELECT
  USING (auth.uid() = viewed_user_id);

-- Only the viewer can insert (record that they saw someone)
CREATE POLICY seen_receipts_insert_viewer
  ON seen_receipts FOR INSERT
  WITH CHECK (auth.uid() = viewer_id);
