-- ============================================================================
-- SEAT RPC FUNCTIONS & TRIGGERS
-- ============================================================================
-- Updates existing RPCs to link seats on connection acceptance.
-- Adds new RPCs for seat management (renew, cancel, link, enforce).
-- Adds trigger to clear seat when connection is removed.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. UPDATED RPC: accept_invite — link seat to new connection
-- ============================================================================

CREATE OR REPLACE FUNCTION accept_invite(p_code TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invite invite_codes%ROWTYPE;
    v_user_id UUID := auth.uid();
    v_now TIMESTAMPTZ := NOW();
    v_a UUID;
    v_b UUID;
    v_connection_id UUID;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Validate invite code (lock row to prevent race conditions)
    SELECT * INTO v_invite
    FROM invite_codes
    WHERE code = p_code
      AND accepted_by IS NULL
      AND expires_at > NOW()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid or expired invite code';
    END IF;

    -- Prevent self-connection
    IF v_invite.creator_id = v_user_id THEN
        RAISE EXCEPTION 'Cannot connect to yourself';
    END IF;

    -- Compute canonical ordering
    IF v_invite.creator_id < v_user_id THEN
        v_a := v_invite.creator_id;
        v_b := v_user_id;
    ELSE
        v_a := v_user_id;
        v_b := v_invite.creator_id;
    END IF;

    -- Check existing connection
    IF EXISTS (
        SELECT 1 FROM connections
        WHERE user_a_id = v_a AND user_b_id = v_b
          AND removed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Connection already exists';
    END IF;

    -- Insert single canonical row
    INSERT INTO connections (user_a_id, user_b_id, created_at)
    VALUES (v_a, v_b, v_now)
    RETURNING id INTO v_connection_id;

    -- Mark invite as accepted
    UPDATE invite_codes
    SET accepted_by = v_user_id, accepted_at = v_now
    WHERE code = p_code;

    -- Link seat to connection and clear invite_code_id
    UPDATE connection_seats
    SET connection_id = v_connection_id, invite_code_id = NULL
    WHERE invite_code_id = v_invite.id;
END;
$$;

-- ============================================================================
-- 2. UPDATED RPC: accept_connection_request — link seat to new connection
-- ============================================================================

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
    v_a UUID;
    v_b UUID;
    v_connection_id UUID;
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

    -- Compute canonical ordering
    IF v_request.from_user_id < v_request.to_user_id THEN
        v_a := v_request.from_user_id;
        v_b := v_request.to_user_id;
    ELSE
        v_a := v_request.to_user_id;
        v_b := v_request.from_user_id;
    END IF;

    -- Insert single canonical row
    INSERT INTO connections (user_a_id, user_b_id, created_at)
    VALUES (v_a, v_b, v_now)
    RETURNING id INTO v_connection_id;

    -- Mark request as accepted
    UPDATE connection_requests
    SET status = 'accepted', responded_at = v_now
    WHERE id = p_request_id;

    -- Link seat to connection and clear connection_request_id
    UPDATE connection_seats
    SET connection_id = v_connection_id, connection_request_id = NULL
    WHERE connection_request_id = p_request_id;
END;
$$;

-- ============================================================================
-- 3. UPDATED RPC: send_connection_request — optional p_seat_id param
-- ============================================================================

CREATE OR REPLACE FUNCTION send_connection_request(p_to_email TEXT, p_seat_id UUID DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_from_user_id UUID := auth.uid();
    v_to_user_id UUID;
    v_request_id UUID;
    v_a UUID;
    v_b UUID;
BEGIN
    IF v_from_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- If seat_id provided, validate ownership and emptiness
    IF p_seat_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM connection_seats
            WHERE id = p_seat_id
              AND owner_id = v_from_user_id
              AND connection_id IS NULL
              AND invite_code_id IS NULL
              AND connection_request_id IS NULL
              AND expires_at > NOW()
        ) THEN
            RAISE EXCEPTION 'Seat not available';
        END IF;
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

    -- Compute canonical ordering for connection check
    IF v_from_user_id < v_to_user_id THEN
        v_a := v_from_user_id;
        v_b := v_to_user_id;
    ELSE
        v_a := v_to_user_id;
        v_b := v_from_user_id;
    END IF;

    -- Check if already connected (single canonical row)
    IF EXISTS (
        SELECT 1 FROM connections
        WHERE user_a_id = v_a AND user_b_id = v_b
          AND removed_at IS NULL
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

    -- Link seat to the request if seat_id provided
    IF p_seat_id IS NOT NULL AND v_request_id IS NOT NULL THEN
        UPDATE connection_seats
        SET connection_request_id = v_request_id
        WHERE id = p_seat_id
          AND owner_id = v_from_user_id;
    END IF;

    RETURN v_request_id;
END;
$$;

-- ============================================================================
-- 4. NEW RPC: renew_seat — extend expiry by 7 days, unpause connection
-- ============================================================================

CREATE OR REPLACE FUNCTION renew_seat(p_seat_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_seat connection_seats%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT * INTO v_seat
    FROM connection_seats
    WHERE id = p_seat_id
      AND owner_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Seat not found';
    END IF;

    -- Extend expiry by 7 days from now
    UPDATE connection_seats
    SET expires_at = NOW() + INTERVAL '7 days',
        renewed_at = NOW()
    WHERE id = p_seat_id;

    -- If seat has a connection that is paused, reactivate it
    IF v_seat.connection_id IS NOT NULL THEN
        UPDATE connections
        SET status = 'active'
        WHERE id = v_seat.connection_id
          AND status = 'paused';
    END IF;
END;
$$;

-- ============================================================================
-- 5. NEW RPC: cancel_seat_invite — clear pending invite/request from seat
-- ============================================================================

CREATE OR REPLACE FUNCTION cancel_seat_invite(p_seat_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_seat connection_seats%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT * INTO v_seat
    FROM connection_seats
    WHERE id = p_seat_id
      AND owner_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Seat not found';
    END IF;

    -- Expire linked invite code if present
    IF v_seat.invite_code_id IS NOT NULL THEN
        UPDATE invite_codes
        SET expires_at = NOW()
        WHERE id = v_seat.invite_code_id;
    END IF;

    -- Decline linked connection request if present
    IF v_seat.connection_request_id IS NOT NULL THEN
        UPDATE connection_requests
        SET status = 'declined', responded_at = NOW()
        WHERE id = v_seat.connection_request_id
          AND status = 'pending';
    END IF;

    -- Clear seat FKs
    UPDATE connection_seats
    SET invite_code_id = NULL,
        connection_request_id = NULL
    WHERE id = p_seat_id;
END;
$$;

-- ============================================================================
-- 6. NEW RPC: link_invite_to_seat — associate an invite code with a seat
-- ============================================================================

CREATE OR REPLACE FUNCTION link_invite_to_seat(p_seat_id UUID, p_invite_code_id UUID)
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

    -- Validate seat: owned by user, empty, not expired
    IF NOT EXISTS (
        SELECT 1 FROM connection_seats
        WHERE id = p_seat_id
          AND owner_id = v_user_id
          AND connection_id IS NULL
          AND invite_code_id IS NULL
          AND connection_request_id IS NULL
          AND expires_at > NOW()
    ) THEN
        RAISE EXCEPTION 'Seat not available';
    END IF;

    -- Validate invite code: owned by user, not expired, not accepted
    IF NOT EXISTS (
        SELECT 1 FROM invite_codes
        WHERE id = p_invite_code_id
          AND creator_id = v_user_id
          AND accepted_by IS NULL
          AND expires_at > NOW()
    ) THEN
        RAISE EXCEPTION 'Invite code not valid';
    END IF;

    UPDATE connection_seats
    SET invite_code_id = p_invite_code_id
    WHERE id = p_seat_id;
END;
$$;

-- ============================================================================
-- 7. NEW RPC: enforce_seat_expirations — called on page load
-- ============================================================================
-- For the given user: finds all expired seats and:
-- - Pauses connections (status='paused')
-- - Expires invite codes
-- - Declines pending requests
-- - Clears seat FKs

CREATE OR REPLACE FUNCTION enforce_seat_expirations(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_seat RECORD;
BEGIN
    -- Process each expired seat with a pending or occupied state
    FOR v_seat IN
        SELECT id, connection_id, invite_code_id, connection_request_id
        FROM connection_seats
        WHERE owner_id = p_user_id
          AND expires_at <= NOW()
          AND (connection_id IS NOT NULL OR invite_code_id IS NOT NULL OR connection_request_id IS NOT NULL)
        FOR UPDATE
    LOOP
        -- Pause connection if occupied
        IF v_seat.connection_id IS NOT NULL THEN
            UPDATE connections
            SET status = 'paused'
            WHERE id = v_seat.connection_id
              AND status = 'active';
        END IF;

        -- Expire invite code if pending
        IF v_seat.invite_code_id IS NOT NULL THEN
            UPDATE invite_codes
            SET expires_at = NOW()
            WHERE id = v_seat.invite_code_id
              AND expires_at > NOW();
        END IF;

        -- Decline connection request if pending
        IF v_seat.connection_request_id IS NOT NULL THEN
            UPDATE connection_requests
            SET status = 'declined', responded_at = NOW()
            WHERE id = v_seat.connection_request_id
              AND status = 'pending';
        END IF;

        -- Clear seat FKs
        UPDATE connection_seats
        SET connection_id = NULL,
            invite_code_id = NULL,
            connection_request_id = NULL
        WHERE id = v_seat.id;
    END LOOP;
END;
$$;

-- ============================================================================
-- 8. TRIGGER: clear_seat_on_connection_remove
-- ============================================================================
-- When a connection is removed (removed_at set or status='removed'),
-- clear the connection_id from any associated seat.

CREATE OR REPLACE FUNCTION clear_seat_on_connection_remove()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.removed_at IS NOT NULL AND OLD.removed_at IS NULL)
       OR (NEW.status = 'removed' AND OLD.status != 'removed') THEN
        UPDATE connection_seats
        SET connection_id = NULL
        WHERE connection_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER clear_seat_on_connection_remove_trigger
    AFTER UPDATE ON public.connections
    FOR EACH ROW
    EXECUTE FUNCTION clear_seat_on_connection_remove();

-- ============================================================================
-- 9. COMMENTS
-- ============================================================================

COMMENT ON FUNCTION renew_seat(UUID) IS 'Extends seat expiry by 7 days and reactivates paused connection';
COMMENT ON FUNCTION cancel_seat_invite(UUID) IS 'Cancels pending invite/request on a seat, clearing FKs';
COMMENT ON FUNCTION link_invite_to_seat(UUID, UUID) IS 'Links a generated invite code to a specific empty seat';
COMMENT ON FUNCTION enforce_seat_expirations(UUID) IS 'Enforces expired seats: pauses connections, expires invites, declines requests';
COMMENT ON FUNCTION clear_seat_on_connection_remove() IS 'Trigger: clears connection_id from seat when connection is removed';

COMMIT;
