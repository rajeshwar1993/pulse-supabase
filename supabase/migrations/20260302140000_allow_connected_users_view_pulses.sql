-- Fix: Allow connected users to view each other's daily pulses.
-- Previously, the only SELECT policy restricted reads to auth.uid() = user_id,
-- which meant the dashboard could never show a connected user's pulse status.

CREATE POLICY "Users can view connected users pulses"
    ON public.daily_pulses
    FOR SELECT
    USING (
        user_id IN (
            SELECT user_b_id FROM public.connections
            WHERE user_a_id = auth.uid() AND removed_at IS NULL AND status = 'active'
            UNION ALL
            SELECT user_a_id FROM public.connections
            WHERE user_b_id = auth.uid() AND removed_at IS NULL AND status = 'active'
        )
    );
