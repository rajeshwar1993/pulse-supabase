-- Connection Requests: direct email-based invites with pending/accepted/declined states.
-- Enables targeted connection requests to known users, with dashboard notifications.

-- =============================================================================
-- TABLE: connection_requests
-- =============================================================================

CREATE TABLE public.connection_requests (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    from_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'accepted', 'declined')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ,

    -- Cannot send a request to yourself
    CONSTRAINT no_self_request CHECK (from_user_id != to_user_id),

    -- Response logic: pending → NULL responded_at; accepted/declined → NOT NULL
    CONSTRAINT response_timestamp_logic CHECK (
        (status = 'pending' AND responded_at IS NULL)
        OR (status IN ('accepted', 'declined') AND responded_at IS NOT NULL)
    )
);

-- Only one pending request per direction at a time
CREATE UNIQUE INDEX connection_requests_pending_unique
    ON public.connection_requests (from_user_id, to_user_id)
    WHERE status = 'pending';

-- Fast lookup: pending requests for a user (dashboard banner)
CREATE INDEX connection_requests_to_user_pending_idx
    ON public.connection_requests (to_user_id)
    WHERE status = 'pending';

-- Lookup requests sent by a user
CREATE INDEX connection_requests_from_user_idx
    ON public.connection_requests (from_user_id);

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

ALTER TABLE public.connection_requests ENABLE ROW LEVEL SECURITY;

-- Sender can view their own sent requests
CREATE POLICY "connection_requests_select_sender"
    ON public.connection_requests FOR SELECT
    USING (auth.uid() = from_user_id);

-- Receiver can view requests sent to them
CREATE POLICY "connection_requests_select_receiver"
    ON public.connection_requests FOR SELECT
    USING (auth.uid() = to_user_id);

-- Sender can insert requests (only as themselves)
CREATE POLICY "connection_requests_insert_sender"
    ON public.connection_requests FOR INSERT
    WITH CHECK (auth.uid() = from_user_id);

-- Receiver can update requests sent to them (accept/decline)
CREATE POLICY "connection_requests_update_receiver"
    ON public.connection_requests FOR UPDATE
    USING (auth.uid() = to_user_id);

-- =============================================================================
-- RPC: send_connection_request(p_to_email TEXT) → UUID | NULL
-- =============================================================================
-- Lookup user by email. Returns NULL silently if not found (privacy-safe).
-- Validates: not self, not already connected, no pending request in either direction.

CREATE OR REPLACE FUNCTION send_connection_request(p_to_email TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_from_user_id UUID := auth.uid();
    v_to_user_id UUID;
    v_request_id UUID;
BEGIN
    IF v_from_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Lookup target user by email (case-insensitive)
    SELECT id INTO v_to_user_id
    FROM profiles
    WHERE LOWER(email) = LOWER(p_to_email);

    -- If user not found, return NULL silently (privacy: don't reveal existence)
    IF v_to_user_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Cannot send request to yourself
    IF v_to_user_id = v_from_user_id THEN
        RAISE EXCEPTION 'Cannot send a connection request to yourself';
    END IF;

    -- Check if already connected
    IF EXISTS (
        SELECT 1 FROM connections
        WHERE removed_at IS NULL
          AND (
            (from_user_id = v_from_user_id AND to_user_id = v_to_user_id)
            OR (from_user_id = v_to_user_id AND to_user_id = v_from_user_id)
          )
    ) THEN
        RAISE EXCEPTION 'Already connected with this user';
    END IF;

    -- Check for pending request in either direction
    IF EXISTS (
        SELECT 1 FROM connection_requests
        WHERE status = 'pending'
          AND (
            (from_user_id = v_from_user_id AND to_user_id = v_to_user_id)
            OR (from_user_id = v_to_user_id AND to_user_id = v_from_user_id)
          )
    ) THEN
        RAISE EXCEPTION 'A pending connection request already exists';
    END IF;

    -- Insert the request
    INSERT INTO connection_requests (from_user_id, to_user_id)
    VALUES (v_from_user_id, v_to_user_id)
    RETURNING id INTO v_request_id;

    RETURN v_request_id;
END;
$$;

-- =============================================================================
-- RPC: accept_connection_request(p_request_id UUID) → VOID
-- =============================================================================
-- Validates receiver, locks row, creates bidirectional connection, marks accepted.

CREATE OR REPLACE FUNCTION accept_connection_request(p_request_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_request connection_requests%ROWTYPE;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Lock the request row to prevent race conditions
    SELECT * INTO v_request
    FROM connection_requests
    WHERE id = p_request_id
      AND to_user_id = v_user_id
      AND status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Connection request not found or already processed';
    END IF;

    -- Temporarily disable the duplicate-check trigger for bidirectional insert
    ALTER TABLE connections DISABLE TRIGGER prevent_duplicate_connection_trigger;

    -- Create bidirectional connection
    INSERT INTO connections (from_user_id, to_user_id, created_at)
    VALUES
        (v_request.from_user_id, v_request.to_user_id, v_now),
        (v_request.to_user_id, v_request.from_user_id, v_now);

    ALTER TABLE connections ENABLE TRIGGER prevent_duplicate_connection_trigger;

    -- Mark request as accepted
    UPDATE connection_requests
    SET status = 'accepted', responded_at = v_now
    WHERE id = p_request_id;
END;
$$;

-- =============================================================================
-- RPC: decline_connection_request(p_request_id UUID) → VOID
-- =============================================================================

CREATE OR REPLACE FUNCTION decline_connection_request(p_request_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Update only if the current user is the receiver and request is pending
    UPDATE connection_requests
    SET status = 'declined', responded_at = NOW()
    WHERE id = p_request_id
      AND to_user_id = v_user_id
      AND status = 'pending';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Connection request not found or already processed';
    END IF;
END;
$$;
