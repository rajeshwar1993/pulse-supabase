-- RPC: get_connection_stats
-- Returns aggregated relationship metrics for a connection:
--   connected since, shared streak (current + longest),
--   pulse sync rate, and other user's profile info.
--
-- Uses inverse pulse storage model: pulsed dates = all dates
-- from join_day to last_pulse_date MINUS missed_pulses rows.

CREATE OR REPLACE FUNCTION public.get_connection_stats(p_connection_id UUID)
RETURNS TABLE (
  connection_created_at TIMESTAMPTZ,
  total_days_connected INT,
  days_both_pulsed INT,
  sync_rate INT,
  shared_streak_current INT,
  shared_streak_longest INT,
  other_user_id UUID,
  other_display_name TEXT,
  other_avatar_url TEXT,
  other_timezone TEXT,
  other_current_streak INT,
  other_longest_streak INT,
  other_last_pulse_date DATE
) AS $$
DECLARE
  v_conn RECORD;
  v_caller_id UUID;
  v_other_id UUID;
  v_caller_tz TEXT;
  v_today DATE;
  v_conn_start_day DATE;
  v_total_days INT;
  v_both_pulsed INT;
  v_shared_current INT;
  v_shared_longest INT;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Fetch connection row
  SELECT c.id, c.user_a_id, c.user_b_id, c.created_at
    INTO v_conn
    FROM public.connections c
    WHERE c.id = p_connection_id
      AND c.removed_at IS NULL
      AND c.status = 'active';

  IF v_conn IS NULL THEN
    RAISE EXCEPTION 'Connection not found';
  END IF;

  -- Verify caller is a participant
  IF v_caller_id != v_conn.user_a_id AND v_caller_id != v_conn.user_b_id THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Determine the other user
  v_other_id := CASE
    WHEN v_caller_id = v_conn.user_a_id THEN v_conn.user_b_id
    ELSE v_conn.user_a_id
  END;

  -- Get caller's timezone for pulse-day computation
  SELECT p.timezone INTO v_caller_tz
    FROM public.profiles p WHERE p.id = v_caller_id;

  v_today := public.get_pulse_day_date(now(), COALESCE(v_caller_tz, 'UTC'));
  v_conn_start_day := public.get_pulse_day_date(v_conn.created_at, COALESCE(v_caller_tz, 'UTC'));

  -- Total days connected (inclusive of start day, minimum 1)
  v_total_days := GREATEST((v_today - v_conn_start_day) + 1, 1);

  -- Build pulsed-date sets for both users, then intersect.
  -- For each user: generate_series(effective_start, last_pulse_date) MINUS missed_pulses.
  -- effective_start = MAX(user_join_day, connection_start_day)
  WITH caller_pulsed AS (
    SELECT d::DATE AS pulse_date
      FROM public.profiles p
      CROSS JOIN LATERAL generate_series(
        GREATEST(
          public.get_pulse_day_date(p.created_at, COALESCE(p.timezone, 'UTC')),
          v_conn_start_day
        )::TIMESTAMP,
        COALESCE(p.last_pulse_date, v_conn_start_day)::TIMESTAMP,
        '1 day'::INTERVAL
      ) AS d
      WHERE p.id = v_caller_id
        AND p.last_pulse_date IS NOT NULL
        AND d::DATE NOT IN (
          SELECT mp.missed_date FROM public.missed_pulses mp
            WHERE mp.user_id = v_caller_id
              AND mp.missed_date >= GREATEST(
                public.get_pulse_day_date(p.created_at, COALESCE(p.timezone, 'UTC')),
                v_conn_start_day
              )
              AND mp.missed_date <= p.last_pulse_date
        )
  ),
  other_pulsed AS (
    SELECT d::DATE AS pulse_date
      FROM public.profiles p
      CROSS JOIN LATERAL generate_series(
        GREATEST(
          public.get_pulse_day_date(p.created_at, COALESCE(p.timezone, 'UTC')),
          v_conn_start_day
        )::TIMESTAMP,
        COALESCE(p.last_pulse_date, v_conn_start_day)::TIMESTAMP,
        '1 day'::INTERVAL
      ) AS d
      WHERE p.id = v_other_id
        AND p.last_pulse_date IS NOT NULL
        AND d::DATE NOT IN (
          SELECT mp.missed_date FROM public.missed_pulses mp
            WHERE mp.user_id = v_other_id
              AND mp.missed_date >= GREATEST(
                public.get_pulse_day_date(p.created_at, COALESCE(p.timezone, 'UTC')),
                v_conn_start_day
              )
              AND mp.missed_date <= p.last_pulse_date
        )
  ),
  -- Intersect: days both pulsed
  shared_dates AS (
    SELECT cp.pulse_date
      FROM caller_pulsed cp
      INNER JOIN other_pulsed op ON cp.pulse_date = op.pulse_date
  ),
  -- Islands-and-gaps for shared streaks
  shared_with_islands AS (
    SELECT pulse_date,
           pulse_date - (ROW_NUMBER() OVER (ORDER BY pulse_date))::INT AS island
      FROM shared_dates
  ),
  island_lengths AS (
    SELECT island,
           COUNT(*)::INT AS streak_len,
           MAX(pulse_date) AS island_end
      FROM shared_with_islands
      GROUP BY island
  )
  SELECT
    COUNT(sd.pulse_date)::INT,
    COALESCE(MAX(il.streak_len), 0)::INT,
    -- Current shared streak: longest island that ends today or yesterday
    COALESCE(
      (SELECT il2.streak_len FROM island_lengths il2
        WHERE il2.island_end >= v_today - 1
        ORDER BY il2.island_end DESC LIMIT 1),
      0
    )::INT
    INTO v_both_pulsed, v_shared_longest, v_shared_current
    FROM shared_dates sd
    LEFT JOIN island_lengths il ON TRUE;

  -- Return the result
  RETURN QUERY
    SELECT
      v_conn.created_at AS connection_created_at,
      v_total_days AS total_days_connected,
      v_both_pulsed AS days_both_pulsed,
      CASE WHEN v_total_days > 0
        THEN ROUND(v_both_pulsed * 100.0 / v_total_days)::INT
        ELSE 0
      END AS sync_rate,
      v_shared_current AS shared_streak_current,
      v_shared_longest AS shared_streak_longest,
      v_other_id AS other_user_id,
      op.display_name AS other_display_name,
      op.avatar_url AS other_avatar_url,
      COALESCE(op.timezone, 'UTC') AS other_timezone,
      op.current_streak AS other_current_streak,
      op.longest_streak AS other_longest_streak,
      op.last_pulse_date AS other_last_pulse_date
    FROM public.profiles op
    WHERE op.id = v_other_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_connection_stats IS
  'Returns aggregated relationship metrics for a connection: shared streak, sync rate, and partner profile info.';
