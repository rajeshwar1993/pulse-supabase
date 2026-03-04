-- Allow users to update their own pulse rows (e.g. refreshing created_at timestamp)
-- Note: The streak trigger (update_streak_after_pulse) only fires on INSERT,
-- so updating created_at will not re-trigger streak logic.

CREATE POLICY "daily_pulses_update_own"
    ON public.daily_pulses
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);
