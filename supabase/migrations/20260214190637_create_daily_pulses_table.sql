-- Create daily_pulses table
-- This table stores daily check-ins (pulses) for users
-- Each pulse represents that a user opened the app on a given day
-- Daily reset occurs at 4:00 AM local time

CREATE TABLE IF NOT EXISTS public.daily_pulses (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status TEXT NOT NULL DEFAULT 'active'
);

-- Enable Row Level Security
ALTER TABLE public.daily_pulses ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can view their own pulses
CREATE POLICY "Users can view own pulses"
    ON public.daily_pulses
    FOR SELECT
    USING (auth.uid() = user_id);

-- RLS Policy: Users can insert their own pulses
CREATE POLICY "Users can insert own pulses"
    ON public.daily_pulses
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Create index for performance (queries filtered by user_id and created_at)
CREATE INDEX IF NOT EXISTS daily_pulses_user_id_created_at_idx
    ON public.daily_pulses(user_id, created_at DESC);

-- Add comment for documentation
COMMENT ON TABLE public.daily_pulses IS 'Stores daily pulse check-ins for users. Pulse Day starts at 4:00 AM local time.';
COMMENT ON COLUMN public.daily_pulses.user_id IS 'Reference to the user who sent the pulse';
COMMENT ON COLUMN public.daily_pulses.created_at IS 'Timestamp when the pulse was created';
COMMENT ON COLUMN public.daily_pulses.status IS 'Status of the pulse (default: active)';
