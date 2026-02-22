-- Fix: accept_invite RPC fails because the prevent_duplicate_connection trigger
-- blocks the second row of the bidirectional INSERT within the same statement.
-- Solution: disable the trigger inside the RPC (runs as SECURITY DEFINER / postgres).
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

  -- Check existing connection
  IF EXISTS (
    SELECT 1 FROM connections
    WHERE removed_at IS NULL
      AND (
        (from_user_id = v_user_id AND to_user_id = v_invite.creator_id)
        OR (from_user_id = v_invite.creator_id AND to_user_id = v_user_id)
      )
  ) THEN
    RAISE EXCEPTION 'Connection already exists';
  END IF;

  -- Temporarily disable the duplicate-check trigger for the bidirectional insert
  ALTER TABLE connections DISABLE TRIGGER prevent_duplicate_connection_trigger;

  INSERT INTO connections (from_user_id, to_user_id, created_at)
  VALUES
    (v_invite.creator_id, v_user_id, v_now),
    (v_user_id, v_invite.creator_id, v_now);

  ALTER TABLE connections ENABLE TRIGGER prevent_duplicate_connection_trigger;

  -- Mark invite as accepted
  UPDATE invite_codes
  SET accepted_by = v_user_id, accepted_at = v_now
  WHERE code = p_code;
END;
$$;
