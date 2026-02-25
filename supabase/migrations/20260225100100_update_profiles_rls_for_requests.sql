-- Extend profiles SELECT policy to include users involved in pending connection requests.
-- This allows the dashboard banner to show requester name/avatar.

-- Drop the existing policy that only covers self + connected users
DROP POLICY IF EXISTS "Users can view own and connected profiles" ON profiles;

-- Re-create with broader scope: self + connected + pending request participants
CREATE POLICY "Users can view own and connected profiles"
  ON profiles FOR SELECT
  USING (
    auth.uid() = id
    OR id IN (
      -- Active connections
      SELECT to_user_id FROM connections
      WHERE from_user_id = auth.uid() AND removed_at IS NULL
      UNION
      SELECT from_user_id FROM connections
      WHERE to_user_id = auth.uid() AND removed_at IS NULL
      UNION
      -- Pending connection requests (sender can see receiver, receiver can see sender)
      SELECT to_user_id FROM connection_requests
      WHERE from_user_id = auth.uid() AND status = 'pending'
      UNION
      SELECT from_user_id FROM connection_requests
      WHERE to_user_id = auth.uid() AND status = 'pending'
    )
  );
