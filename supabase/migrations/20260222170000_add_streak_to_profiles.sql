-- Add streak tracking columns to profiles table
-- Streaks track consecutive days of pulsing (using 4 AM pulse-day boundary)

ALTER TABLE public.profiles
  ADD COLUMN current_streak INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN longest_streak INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN last_pulse_date DATE;

-- Helper function: compute the logical "pulse day" date for a given timestamp and timezone.
-- Pulse Day resets at 4 AM local time, so a pulse at 3 AM belongs to the previous day.
CREATE OR REPLACE FUNCTION public.get_pulse_day_date(ts TIMESTAMPTZ, tz TEXT)
RETURNS DATE AS $$
  SELECT ((ts AT TIME ZONE tz) - INTERVAL '4 hours')::DATE;
$$ LANGUAGE SQL IMMUTABLE;

-- Trigger function: update streak columns whenever a new pulse is inserted.
-- Runs as SECURITY DEFINER so it can update profiles regardless of RLS.
CREATE OR REPLACE FUNCTION public.update_streak_on_pulse()
RETURNS TRIGGER AS $$
DECLARE
  user_tz TEXT;
  pulse_day DATE;
  prev_pulse_date DATE;
  prev_streak INTEGER;
  prev_longest INTEGER;
BEGIN
  -- Get user's timezone from their profile
  SELECT timezone, last_pulse_date, current_streak, longest_streak
    INTO user_tz, prev_pulse_date, prev_streak, prev_longest
    FROM public.profiles
    WHERE id = NEW.user_id;

  -- Compute the pulse day for this new pulse
  pulse_day := public.get_pulse_day_date(NEW.created_at, user_tz);

  IF prev_pulse_date IS NULL OR pulse_day > prev_pulse_date + 1 THEN
    -- First pulse ever OR streak broken (missed one or more days)
    UPDATE public.profiles SET
      current_streak = 1,
      longest_streak = GREATEST(prev_longest, 1),
      last_pulse_date = pulse_day
    WHERE id = NEW.user_id;

  ELSIF pulse_day = prev_pulse_date + 1 THEN
    -- Consecutive day — increment streak
    UPDATE public.profiles SET
      current_streak = prev_streak + 1,
      longest_streak = GREATEST(prev_longest, prev_streak + 1),
      last_pulse_date = pulse_day
    WHERE id = NEW.user_id;

  -- ELSE: pulse_day = prev_pulse_date (same day, already counted — no change)
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach trigger to daily_pulses table
CREATE TRIGGER update_streak_after_pulse
  AFTER INSERT ON public.daily_pulses
  FOR EACH ROW
  EXECUTE FUNCTION public.update_streak_on_pulse();

-- Backfill: compute streaks from existing daily_pulses history.
-- For each user, iterate through pulse days in order and compute streak.
DO $$
DECLARE
  r RECORD;
  user_tz TEXT;
  pulse_day DATE;
  prev_date DATE;
  cur_streak INTEGER;
  max_streak INTEGER;
  last_date DATE;
BEGIN
  FOR r IN
    SELECT DISTINCT dp.user_id, p.timezone
    FROM public.daily_pulses dp
    JOIN public.profiles p ON p.id = dp.user_id
  LOOP
    user_tz := r.timezone;
    prev_date := NULL;
    cur_streak := 0;
    max_streak := 0;
    last_date := NULL;

    FOR pulse_day IN
      SELECT DISTINCT public.get_pulse_day_date(dp.created_at, user_tz) AS pd
      FROM public.daily_pulses dp
      WHERE dp.user_id = r.user_id
      ORDER BY pd ASC
    LOOP
      IF prev_date IS NULL OR pulse_day > prev_date + 1 THEN
        cur_streak := 1;
      ELSIF pulse_day = prev_date + 1 THEN
        cur_streak := cur_streak + 1;
      END IF;
      -- pulse_day = prev_date means same day, skip

      IF cur_streak > max_streak THEN
        max_streak := cur_streak;
      END IF;

      prev_date := pulse_day;
      last_date := pulse_day;
    END LOOP;

    UPDATE public.profiles SET
      current_streak = cur_streak,
      longest_streak = max_streak,
      last_pulse_date = last_date
    WHERE id = r.user_id;
  END LOOP;
END;
$$;

COMMENT ON COLUMN public.profiles.current_streak IS 'Current consecutive pulse-day streak';
COMMENT ON COLUMN public.profiles.longest_streak IS 'All-time longest consecutive pulse-day streak';
COMMENT ON COLUMN public.profiles.last_pulse_date IS 'Logical pulse-day date of most recent pulse (4 AM boundary)';
