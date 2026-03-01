-- Fix: streak trigger should delete any missed_pulses row for the pulse day.
-- A stale row from the backfill migration could mark a pulsed day as missed,
-- causing get_pulse_calendar to exclude it from results.

-- 1. Clean up any existing stale missed_pulses rows where the user actually pulsed
DELETE FROM public.missed_pulses mp
  WHERE mp.missed_date IN (
    SELECT DISTINCT public.get_pulse_day_date(dp.created_at,
      (SELECT timezone FROM public.profiles WHERE id = dp.user_id))
    FROM public.daily_pulses dp
    WHERE dp.user_id = mp.user_id
  );

-- 2. Add safety DELETE to the streak trigger
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

  -- Safety: remove any missed_pulses row for this pulse day
  DELETE FROM public.missed_pulses
    WHERE user_id = NEW.user_id AND missed_date = pulse_day;

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
