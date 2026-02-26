-- ============================================================================
-- CONNECTION SEATS SYSTEM
-- ============================================================================
-- Introduces a slot-based model for connections. Each user gets 3 seats that
-- govern their connection lifecycle. Free users get 3 seats with 1-week expiry.
--
-- Seat state is derived on read (not stored):
--   empty:    all FKs null, not expired
--   pending:  invite_code_id OR connection_request_id set, not expired
--   occupied: connection_id set, not expired
--   expired:  expires_at <= NOW()
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. NEW TABLE: connection_seats
-- ============================================================================

CREATE TABLE public.connection_seats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    seat_number SMALLINT NOT NULL CHECK (seat_number BETWEEN 1 AND 99),
    expires_at TIMESTAMPTZ NOT NULL,
    connection_id UUID REFERENCES public.connections(id) ON DELETE SET NULL,
    invite_code_id UUID REFERENCES public.invite_codes(id) ON DELETE SET NULL,
    connection_request_id UUID REFERENCES public.connection_requests(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    renewed_at TIMESTAMPTZ,

    -- Only one pending mechanism at a time (invite code XOR connection request)
    CONSTRAINT seat_single_pending CHECK (
        num_nonnulls(invite_code_id, connection_request_id) <= 1
    ),

    -- Each owner can have only one seat per number
    CONSTRAINT unique_seat_per_owner UNIQUE (owner_id, seat_number)
);

-- ============================================================================
-- 2. RLS POLICIES
-- ============================================================================

ALTER TABLE public.connection_seats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "connection_seats_select_own"
    ON public.connection_seats FOR SELECT
    USING (auth.uid() = owner_id);

CREATE POLICY "connection_seats_insert_own"
    ON public.connection_seats FOR INSERT
    WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "connection_seats_update_own"
    ON public.connection_seats FOR UPDATE
    USING (auth.uid() = owner_id);

-- ============================================================================
-- 3. INDEXES
-- ============================================================================

-- Primary lookup: all seats for an owner
CREATE INDEX connection_seats_owner_idx
    ON public.connection_seats(owner_id);

-- Sparse indexes for FK lookups (only index non-null rows)
CREATE INDEX connection_seats_connection_idx
    ON public.connection_seats(connection_id)
    WHERE connection_id IS NOT NULL;

CREATE INDEX connection_seats_invite_code_idx
    ON public.connection_seats(invite_code_id)
    WHERE invite_code_id IS NOT NULL;

CREATE INDEX connection_seats_connection_request_idx
    ON public.connection_seats(connection_request_id)
    WHERE connection_request_id IS NOT NULL;

-- ============================================================================
-- 4. ADD status COLUMN TO connections
-- ============================================================================

ALTER TABLE public.connections
    ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'paused', 'removed'));

-- ============================================================================
-- 5. AUTO-CREATE TRIGGER: 3 seats on new profile
-- ============================================================================

CREATE OR REPLACE FUNCTION create_default_seats()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.connection_seats (owner_id, seat_number, expires_at)
    VALUES
        (NEW.id, 1, NOW() + INTERVAL '7 days'),
        (NEW.id, 2, NOW() + INTERVAL '7 days'),
        (NEW.id, 3, NOW() + INTERVAL '7 days');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER create_seats_on_profile_insert
    AFTER INSERT ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION create_default_seats();

-- ============================================================================
-- 6. SEED EXISTING USERS WITH SEATS
-- ============================================================================
-- Best-effort: create 3 seats per existing profile and assign active
-- connections to user_a_id's first available seats.

-- Create 3 seats per existing profile (skip those that already have seats)
INSERT INTO public.connection_seats (owner_id, seat_number, expires_at)
SELECT p.id, s.n, NOW() + INTERVAL '7 days'
FROM public.profiles p
CROSS JOIN (VALUES (1), (2), (3)) AS s(n)
WHERE NOT EXISTS (
    SELECT 1 FROM public.connection_seats cs
    WHERE cs.owner_id = p.id AND cs.seat_number = s.n
);

-- Best-effort assign active connections to user_a_id's seats
-- (since original inviter is unknown, assign to user_a_id)
WITH ranked_connections AS (
    SELECT
        c.id AS connection_id,
        c.user_a_id AS owner_id,
        ROW_NUMBER() OVER (PARTITION BY c.user_a_id ORDER BY c.created_at) AS rn
    FROM public.connections c
    WHERE c.removed_at IS NULL
      AND c.status = 'active'
)
UPDATE public.connection_seats cs
SET connection_id = rc.connection_id
FROM ranked_connections rc
WHERE cs.owner_id = rc.owner_id
  AND cs.seat_number = rc.rn
  AND cs.connection_id IS NULL
  AND rc.rn <= 3;

-- ============================================================================
-- 7. COMMENTS
-- ============================================================================

COMMENT ON TABLE public.connection_seats IS 'Slot-based connection system — each user gets N seats that govern their connection lifecycle';

COMMIT;
