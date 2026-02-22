-- Fix: Users cannot see connected users' profiles due to restrictive RLS.
-- The connections page joins profiles to show display_name and avatar_url,
-- but the existing "Users can view own profile" policy blocks viewing
-- other users' profiles entirely.
--
-- Solution: Allow authenticated users to view profiles of their active connections.
-- This replaces the restrictive "own profile only" SELECT policy with one that
-- also includes connected users.

-- Drop the old restrictive policy
DROP POLICY IF EXISTS "Users can view own profile" ON profiles;

-- Create a broader policy: own profile + connected users' profiles
CREATE POLICY "Users can view own and connected profiles"
  ON profiles FOR SELECT
  USING (
    auth.uid() = id
    OR id IN (
      SELECT to_user_id FROM connections
      WHERE from_user_id = auth.uid() AND removed_at IS NULL
      UNION
      SELECT from_user_id FROM connections
      WHERE to_user_id = auth.uid() AND removed_at IS NULL
    )
  );
