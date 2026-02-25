-- ============================================================================
-- MIGRATE CONNECTIONS TO SINGLE-ROW MODEL
-- ============================================================================
-- Converts from bidirectional design (two rows per connection: A→B and B→A)
-- to single-row canonical ordering (user_a_id < user_b_id).
--
-- Benefits:
-- - RPCs no longer need to disable triggers for bidirectional insert
-- - removeConnection() correctly removes the single row
-- - RLS and existence checks are simpler
-- - UNIQUE + CHECK constraints enforce canonical ordering
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. DEDUPLICATE EXISTING DATA
-- ============================================================================
-- Delete the "reverse" row from each bidirectional pair.
-- Keep the row where from_user_id < to_user_id.

DELETE FROM public.connections c1
USING public.connections c2
WHERE c1.from_user_id = c2.to_user_id
  AND c1.to_user_id = c2.from_user_id
  AND c1.from_user_id > c1.to_user_id;

-- ============================================================================
-- 2. RENAME COLUMNS
-- ============================================================================

-- connections table
ALTER TABLE public.connections RENAME COLUMN from_user_id TO user_a_id;
ALTER TABLE public.connections RENAME COLUMN to_user_id TO user_b_id;

-- Rename FK constraints (critical for Supabase PostgREST joins)
ALTER TABLE public.connections
  RENAME CONSTRAINT connections_from_user_id_fkey TO connections_user_a_id_fkey;
ALTER TABLE public.connections
  RENAME CONSTRAINT connections_to_user_id_fkey TO connections_user_b_id_fkey;

-- connection_history table
ALTER TABLE public.connection_history RENAME COLUMN from_user_id TO user_a_id;
ALTER TABLE public.connection_history RENAME COLUMN to_user_id TO user_b_id;

ALTER TABLE public.connection_history
  RENAME CONSTRAINT connection_history_from_user_id_fkey TO connection_history_user_a_id_fkey;
ALTER TABLE public.connection_history
  RENAME CONSTRAINT connection_history_to_user_id_fkey TO connection_history_user_b_id_fkey;

-- ============================================================================
-- 3. FIX NON-CANONICAL ROWS
-- ============================================================================
-- Swap user_a_id and user_b_id where user_a_id > user_b_id

UPDATE public.connections
SET user_a_id = user_b_id, user_b_id = user_a_id
WHERE user_a_id > user_b_id;

UPDATE public.connection_history
SET user_a_id = user_b_id, user_b_id = user_a_id
WHERE user_a_id > user_b_id;

-- ============================================================================
-- 4. UPDATE CONSTRAINTS AND INDEXES
-- ============================================================================

-- Drop old constraints
ALTER TABLE public.connections DROP CONSTRAINT no_self_connection;
ALTER TABLE public.connections DROP CONSTRAINT unique_connection;

-- Add new constraints
ALTER TABLE public.connections
  ADD CONSTRAINT canonical_user_order CHECK (user_a_id < user_b_id);
ALTER TABLE public.connections
  ADD CONSTRAINT unique_connection UNIQUE (user_a_id, user_b_id);

-- Drop old indexes
DROP INDEX IF EXISTS connections_from_user_idx;
DROP INDEX IF EXISTS connections_to_user_idx;

-- Create new indexes
CREATE INDEX connections_user_a_idx ON public.connections(user_a_id)
    WHERE removed_at IS NULL;
CREATE INDEX connections_user_b_idx ON public.connections(user_b_id)
    WHERE removed_at IS NULL;

-- ============================================================================
-- 5. DROP DUPLICATE PREVENTION TRIGGER
-- ============================================================================
-- The UNIQUE constraint + canonical ordering handles this now.

DROP TRIGGER IF EXISTS prevent_duplicate_connection_trigger ON public.connections;
DROP FUNCTION IF EXISTS prevent_duplicate_connection();

-- ============================================================================
-- 6. REPLACE RLS POLICIES
-- ============================================================================

-- connections: SELECT
DROP POLICY IF EXISTS "Users can view own connections" ON public.connections;
CREATE POLICY "Users can view own connections"
    ON public.connections FOR SELECT
    USING (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- connections: INSERT
DROP POLICY IF EXISTS "Users can insert connections via invite" ON public.connections;
CREATE POLICY "Users can insert connections via invite"
    ON public.connections FOR INSERT
    WITH CHECK (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- connections: UPDATE
DROP POLICY IF EXISTS "Users can update (remove) own connections" ON public.connections;
CREATE POLICY "Users can update (remove) own connections"
    ON public.connections FOR UPDATE
    USING (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- connection_history: SELECT
DROP POLICY IF EXISTS "Users can view own connection history" ON public.connection_history;
CREATE POLICY "Users can view own connection history"
    ON public.connection_history FOR SELECT
    USING (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- profiles: simplified connection subquery
DROP POLICY IF EXISTS "Users can view own and connected profiles" ON public.profiles;
CREATE POLICY "Users can view own and connected profiles"
    ON public.profiles FOR SELECT
    USING (
        auth.uid() = id
        OR id IN (
            -- Active connections (single-row model)
            SELECT user_b_id FROM connections
            WHERE user_a_id = auth.uid() AND removed_at IS NULL
            UNION
            SELECT user_a_id FROM connections
            WHERE user_b_id = auth.uid() AND removed_at IS NULL
            UNION
            -- Pending connection requests (sender can see receiver, receiver can see sender)
            SELECT to_user_id FROM connection_requests
            WHERE from_user_id = auth.uid() AND status = 'pending'
            UNION
            SELECT from_user_id FROM connection_requests
            WHERE to_user_id = auth.uid() AND status = 'pending'
        )
    );

-- ============================================================================
-- 7. REPLACE RPC FUNCTIONS
-- ============================================================================

-- accept_invite: canonical ordering, single insert, no trigger disable
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
    VALUES (v_a, v_b, v_now);

    -- Mark invite as accepted
    UPDATE invite_codes
    SET accepted_by = v_user_id, accepted_at = v_now
    WHERE code = p_code;
END;
$$;

-- accept_connection_request: canonical ordering, single insert, no trigger disable
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
    VALUES (v_a, v_b, v_now);

    -- Mark request as accepted
    UPDATE connection_requests
    SET status = 'accepted', responded_at = v_now
    WHERE id = p_request_id;
END;
$$;

-- send_connection_request: simplified connection check
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
    v_a UUID;
    v_b UUID;
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

    RETURN v_request_id;
END;
$$;

-- ============================================================================
-- 8. UPDATE TRIGGER FUNCTIONS
-- ============================================================================

-- archive_connection_to_history: use new column names
CREATE OR REPLACE FUNCTION archive_connection_to_history()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.removed_at IS NOT NULL AND OLD.removed_at IS NULL THEN
        INSERT INTO public.connection_history (
            connection_id,
            user_a_id,
            user_b_id,
            removed_at,
            removed_by,
            permanent_delete_at
        ) VALUES (
            NEW.id,
            NEW.user_a_id,
            NEW.user_b_id,
            NEW.removed_at,
            NEW.removed_by,
            NEW.removed_at + INTERVAL '30 days'
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 9. UPDATE TABLE COMMENTS
-- ============================================================================

COMMENT ON TABLE public.connections IS 'User connections — single row per relationship with canonical UUID ordering (user_a_id < user_b_id)';

COMMIT;
