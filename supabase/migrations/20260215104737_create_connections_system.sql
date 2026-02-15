-- ============================================================================
-- UNIT 3: CONNECTIONS SYSTEM
-- ============================================================================
-- This migration creates the complete connections system with:
-- - Bidirectional connections (TWO records per relationship)
-- - Invite codes with 30-day expiry and one-time use
-- - Connection history with 30-day restore window
-- - Business rules enforcement at database level
-- ============================================================================

-- ============================================================================
-- CONNECTIONS TABLE (Bidirectional Design)
-- ============================================================================
CREATE TABLE public.connections (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    from_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_at TIMESTAMPTZ,
    removed_by UUID REFERENCES public.profiles(id),

    -- Constraints
    CONSTRAINT no_self_connection CHECK (from_user_id != to_user_id),
    CONSTRAINT unique_connection UNIQUE (from_user_id, to_user_id)
);

-- Enable RLS
ALTER TABLE public.connections ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view own connections"
    ON public.connections FOR SELECT
    USING (
        auth.uid() = from_user_id
        OR auth.uid() = to_user_id
    );

CREATE POLICY "Users can insert connections via invite"
    ON public.connections FOR INSERT
    WITH CHECK (
        auth.uid() = from_user_id
        OR auth.uid() = to_user_id
    );

CREATE POLICY "Users can update (remove) own connections"
    ON public.connections FOR UPDATE
    USING (
        auth.uid() = from_user_id
        OR auth.uid() = to_user_id
    );

-- Performance indexes
CREATE INDEX connections_from_user_idx ON public.connections(from_user_id)
    WHERE removed_at IS NULL;
CREATE INDEX connections_to_user_idx ON public.connections(to_user_id)
    WHERE removed_at IS NULL;
CREATE INDEX connections_removed_at_idx ON public.connections(removed_at)
    WHERE removed_at IS NOT NULL;

-- ============================================================================
-- INVITE CODES TABLE
-- ============================================================================
CREATE TABLE public.invite_codes (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    creator_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_by UUID REFERENCES public.profiles(id),
    accepted_at TIMESTAMPTZ,

    -- Constraints
    CONSTRAINT code_format CHECK (char_length(code) = 8 AND code ~ '^[A-Za-z2-9]+$'),
    CONSTRAINT valid_expiry CHECK (expires_at > created_at),
    CONSTRAINT acceptance_logic CHECK (
        (accepted_by IS NULL AND accepted_at IS NULL)
        OR (accepted_by IS NOT NULL AND accepted_at IS NOT NULL)
    )
);

-- Enable RLS
ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view own created invites"
    ON public.invite_codes FOR SELECT
    USING (auth.uid() = creator_id);

CREATE POLICY "Users can insert own invites"
    ON public.invite_codes FOR INSERT
    WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can update invites to mark accepted"
    ON public.invite_codes FOR UPDATE
    USING (
        auth.uid() = creator_id
        OR auth.uid() = accepted_by
    );

-- Performance indexes
CREATE INDEX invite_codes_code_idx ON public.invite_codes(code);
CREATE INDEX invite_codes_creator_idx ON public.invite_codes(creator_id);
CREATE INDEX invite_codes_expires_at_idx ON public.invite_codes(expires_at);

-- ============================================================================
-- CONNECTION HISTORY TABLE (30-Day Restore Window)
-- ============================================================================
CREATE TABLE public.connection_history (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    connection_id UUID NOT NULL,
    from_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    removed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_by UUID NOT NULL REFERENCES public.profiles(id),
    permanent_delete_at TIMESTAMPTZ NOT NULL,
    restored_at TIMESTAMPTZ,

    -- Constraint
    CONSTRAINT valid_permanent_delete CHECK (permanent_delete_at > removed_at)
);

-- Enable RLS
ALTER TABLE public.connection_history ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view own connection history"
    ON public.connection_history FOR SELECT
    USING (
        auth.uid() = from_user_id
        OR auth.uid() = to_user_id
    );

-- Performance indexes
CREATE INDEX connection_history_connection_id_idx ON public.connection_history(connection_id);
CREATE INDEX connection_history_permanent_delete_at_idx
    ON public.connection_history(permanent_delete_at)
    WHERE restored_at IS NULL;

-- ============================================================================
-- FUNCTION: Generate Unique Invite Code
-- ============================================================================
CREATE OR REPLACE FUNCTION generate_invite_code()
RETURNS TEXT AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    result TEXT := '';
    i INTEGER;
    code_exists BOOLEAN;
BEGIN
    LOOP
        result := '';
        FOR i IN 1..8 LOOP
            result := result || substr(chars, floor(random() * length(chars) + 1)::integer, 1);
        END LOOP;

        -- Check if code already exists
        SELECT EXISTS(SELECT 1 FROM public.invite_codes WHERE code = result) INTO code_exists;

        EXIT WHEN NOT code_exists;
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- FUNCTION: Archive Connection to History
-- ============================================================================
CREATE OR REPLACE FUNCTION archive_connection_to_history()
RETURNS TRIGGER AS $$
BEGIN
    -- Only archive when removed_at is being set (not on initial insert)
    IF NEW.removed_at IS NOT NULL AND OLD.removed_at IS NULL THEN
        INSERT INTO public.connection_history (
            connection_id,
            from_user_id,
            to_user_id,
            removed_at,
            removed_by,
            permanent_delete_at
        ) VALUES (
            NEW.id,
            NEW.from_user_id,
            NEW.to_user_id,
            NEW.removed_at,
            NEW.removed_by,
            NEW.removed_at + INTERVAL '30 days'
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to archive connections
CREATE TRIGGER archive_connection_trigger
    AFTER UPDATE ON public.connections
    FOR EACH ROW
    EXECUTE FUNCTION archive_connection_to_history();

-- ============================================================================
-- FUNCTION: Cleanup Expired Data
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_expired_data()
RETURNS void AS $$
BEGIN
    -- Delete expired invite codes (older than 30 days and not accepted)
    DELETE FROM public.invite_codes
    WHERE expires_at < NOW()
    AND accepted_by IS NULL;

    -- Permanently delete connections past 30-day restore window
    DELETE FROM public.connections
    WHERE id IN (
        SELECT connection_id
        FROM public.connection_history
        WHERE permanent_delete_at < NOW()
        AND restored_at IS NULL
    );

    -- Delete history records after permanent deletion
    DELETE FROM public.connection_history
    WHERE permanent_delete_at < NOW()
    AND restored_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- FUNCTION: Prevent Duplicate Connections
-- ============================================================================
CREATE OR REPLACE FUNCTION prevent_duplicate_connection()
RETURNS TRIGGER AS $$
BEGIN
    -- Check if reverse connection exists (bidirectional duplicate check)
    IF EXISTS (
        SELECT 1 FROM public.connections
        WHERE from_user_id = NEW.to_user_id
        AND to_user_id = NEW.from_user_id
        AND removed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Connection already exists (reverse direction found)';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to prevent duplicates
CREATE TRIGGER prevent_duplicate_connection_trigger
    BEFORE INSERT ON public.connections
    FOR EACH ROW
    EXECUTE FUNCTION prevent_duplicate_connection();

-- ============================================================================
-- COMMENTS (Documentation)
-- ============================================================================
COMMENT ON TABLE public.connections IS 'Bidirectional user connections - TWO records per relationship';
COMMENT ON TABLE public.invite_codes IS 'Invite codes with 30-day expiry and one-time use';
COMMENT ON TABLE public.connection_history IS 'Soft-deleted connections with 30-day restore window';

COMMENT ON FUNCTION generate_invite_code() IS 'Generates unique 8-character invite code (excludes 0/O/1/I/l)';
COMMENT ON FUNCTION archive_connection_to_history() IS 'Archives removed connections to history table';
COMMENT ON FUNCTION cleanup_expired_data() IS 'Cleans up expired invites and permanently deletes old connections';
COMMENT ON FUNCTION prevent_duplicate_connection() IS 'Prevents duplicate connections (checks both directions)';
