-- Inverse Pulse Storage Migration
--
-- Shifts from storing every pulse (daily_pulses grows unbounded)
-- to storing only missed days (missed_pulses). Historical pulse data
-- derived as: all days from join date to last_pulse_date MINUS missed days.
--
-- daily_pulses is kept for 7 days (for "did I pulse today?" checks),
-- then pruned by a cron job. missed_pulses becomes the authoritative
-- record of non-pulse days, with an optional survey response.

-- ============================================================
-- 1. Rename missed_pulse_surveys → missed_pulses
-- ============================================================

ALTER TABLE missed_pulse_surveys RENAME TO missed_pulses;

-- Rename RLS policies
ALTER POLICY missed_pulse_surveys_select_own ON missed_pulses
  RENAME TO missed_pulses_select_own;

ALTER POLICY missed_pulse_surveys_insert_own ON missed_pulses
  RENAME TO missed_pulses_insert_own;

-- Allow users to update their own rows (needed for upsert survey response)
CREATE POLICY missed_pulses_update_own
  ON missed_pulses FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Rename index
ALTER INDEX idx_missed_pulse_surveys_user_date
  RENAME TO idx_missed_pulses_user_date;

-- Make response nullable (auto-recorded misses have NULL response)
ALTER TABLE missed_pulses ALTER COLUMN response DROP NOT NULL;

-- ============================================================
-- 2. Add total_pulse_count to profiles
-- ============================================================

ALTER TABLE profiles ADD COLUMN total_pulse_count INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN profiles.total_pulse_count
  IS 'Running count of distinct pulse days (incremented by trigger)';

-- ============================================================
-- 3. Enhanced streak trigger: also records missed days & increments counter
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_streak_on_pulse()
RETURNS TRIGGER AS $$
DECLARE
  user_tz TEXT;
  pulse_day DATE;
  prev_pulse_date DATE;
  prev_streak INTEGER;
  prev_longest INTEGER;
BEGIN
  -- Get user's timezone and current streak data
  SELECT timezone, last_pulse_date, current_streak, longest_streak
    INTO user_tz, prev_pulse_date, prev_streak, prev_longest
    FROM public.profiles
    WHERE id = NEW.user_id;

  -- Compute the pulse day for this new pulse
  pulse_day := public.get_pulse_day_date(NEW.created_at, user_tz);

  IF prev_pulse_date IS NULL OR pulse_day > prev_pulse_date + 1 THEN
    -- First pulse ever OR streak broken (missed one or more days)

    -- Bulk-insert missed days (only when there's a gap, not first pulse)
    IF prev_pulse_date IS NOT NULL AND pulse_day > prev_pulse_date + 1 THEN
      INSERT INTO public.missed_pulses (user_id, missed_date)
        SELECT NEW.user_id, d::DATE
        FROM generate_series(
          prev_pulse_date + 1,
          pulse_day - 1,
          '1 day'::INTERVAL
        ) AS d
      ON CONFLICT (user_id, missed_date) DO NOTHING;
    END IF;

    UPDATE public.profiles SET
      current_streak = 1,
      longest_streak = GREATEST(prev_longest, 1),
      last_pulse_date = pulse_day,
      total_pulse_count = total_pulse_count + 1
    WHERE id = NEW.user_id;

  ELSIF pulse_day = prev_pulse_date + 1 THEN
    -- Consecutive day — increment streak
    UPDATE public.profiles SET
      current_streak = prev_streak + 1,
      longest_streak = GREATEST(prev_longest, prev_streak + 1),
      last_pulse_date = pulse_day,
      total_pulse_count = total_pulse_count + 1
    WHERE id = NEW.user_id;

  -- ELSE: pulse_day = prev_pulse_date (same day, already counted — no change)
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 4. Replace get_pulse_calendar RPC (inverse approach)
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_pulse_calendar(p_days INTEGER DEFAULT 30)
RETURNS DATE[] AS $$
DECLARE
  user_tz TEXT;
  today_pulse_day DATE;
  join_day DATE;
  window_start DATE;
  last_pulse DATE;
  result DATE[];
BEGIN
  -- Get user's timezone, join date, and last pulse date
  SELECT timezone,
         public.get_pulse_day_date(created_at, timezone),
         last_pulse_date
    INTO user_tz, join_day, last_pulse
    FROM public.profiles
    WHERE id = auth.uid();

  IF user_tz IS NULL OR last_pulse IS NULL THEN
    RETURN '{}';
  END IF;

  today_pulse_day := public.get_pulse_day_date(now(), user_tz);
  window_start := GREATEST(join_day, today_pulse_day - (p_days - 1));

  -- All dates from window_start to last_pulse_date MINUS missed dates = pulsed dates.
  -- Upper bound is last_pulse_date (not today), so today only appears if user pulsed today.
  SELECT ARRAY_AGG(d::DATE ORDER BY d)
    INTO result
    FROM generate_series(window_start::TIMESTAMP, last_pulse::TIMESTAMP, '1 day'::INTERVAL) AS d
    WHERE d::DATE NOT IN (
      SELECT missed_date
        FROM public.missed_pulses
        WHERE user_id = auth.uid()
          AND missed_date >= window_start
          AND missed_date <= last_pulse
    );

  RETURN COALESCE(result, '{}');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- ============================================================
-- 5. New get_pulsed_dates RPC (dashboard streak timeline)
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_pulsed_dates(p_days INTEGER DEFAULT 12)
RETURNS DATE[] AS $$
BEGIN
  RETURN public.get_pulse_calendar(p_days);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_pulsed_dates
  IS 'Returns pulsed dates for the last N days (default 12). Wrapper around get_pulse_calendar for dashboard use.';

-- ============================================================
-- 6. Backfill existing data
-- ============================================================

DO $$
DECLARE
  r RECORD;
  user_tz TEXT;
  join_day DATE;
  pulse_count INTEGER;
BEGIN
  FOR r IN
    SELECT p.id AS user_id, p.timezone, p.created_at, p.last_pulse_date
    FROM public.profiles p
    WHERE p.last_pulse_date IS NOT NULL
  LOOP
    user_tz := r.timezone;
    join_day := public.get_pulse_day_date(r.created_at, user_tz);

    -- Count distinct pulse days
    SELECT COUNT(DISTINCT public.get_pulse_day_date(dp.created_at, user_tz))
      INTO pulse_count
      FROM public.daily_pulses dp
      WHERE dp.user_id = r.user_id;

    -- Set total_pulse_count
    UPDATE public.profiles
      SET total_pulse_count = pulse_count
      WHERE id = r.user_id;

    -- Insert missed days: all dates from join_day to last_pulse_date
    -- that are NOT in the user's distinct pulse days.
    -- ON CONFLICT DO NOTHING preserves existing survey responses.
    INSERT INTO public.missed_pulses (user_id, missed_date)
      SELECT r.user_id, d::DATE
      FROM generate_series(join_day::TIMESTAMP, r.last_pulse_date::TIMESTAMP, '1 day'::INTERVAL) AS d
      WHERE d::DATE NOT IN (
        SELECT DISTINCT public.get_pulse_day_date(dp.created_at, user_tz)
        FROM public.daily_pulses dp
        WHERE dp.user_id = r.user_id
      )
    ON CONFLICT (user_id, missed_date) DO NOTHING;
  END LOOP;
END;
$$;

-- ============================================================
-- 7. pg_cron pruning job (remote only — no-op if cron extension missing)
-- ============================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'prune-daily-pulses',
      '0 5 * * *',
      'DELETE FROM daily_pulses WHERE created_at < now() - interval ''7 days'''
    );
  END IF;
END;
$$;
