-- Ghost Calendar RPC: returns array of dates the user has pulsed within the last N days.
-- Uses get_pulse_day_date() to account for the 4 AM pulse-day boundary.

CREATE OR REPLACE FUNCTION public.get_pulse_calendar(p_days INTEGER DEFAULT 30)
RETURNS DATE[] AS $$
DECLARE
  user_tz TEXT;
  today_pulse_day DATE;
  result DATE[];
BEGIN
  -- Get user's timezone
  SELECT timezone INTO user_tz
    FROM public.profiles
    WHERE id = auth.uid();

  IF user_tz IS NULL THEN
    RETURN '{}';
  END IF;

  -- Compute today's pulse day
  today_pulse_day := public.get_pulse_day_date(now(), user_tz);

  -- Get distinct pulse dates within the range
  SELECT ARRAY_AGG(DISTINCT pd ORDER BY pd)
    INTO result
    FROM (
      SELECT public.get_pulse_day_date(dp.created_at, user_tz) AS pd
        FROM public.daily_pulses dp
        WHERE dp.user_id = auth.uid()
          AND dp.created_at >= ((today_pulse_day - (p_days - 1)) || ' 04:00:00')::TIMESTAMPTZ AT TIME ZONE user_tz AT TIME ZONE 'UTC'
    ) sub
    WHERE pd >= today_pulse_day - (p_days - 1)
      AND pd <= today_pulse_day;

  RETURN COALESCE(result, '{}');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_pulse_calendar IS 'Returns an array of pulse-day dates for the authenticated user over the last N days (default 30). Used by the Ghost Calendar UI.';
