-- ============================================================================
-- E2E TEST SEED DATA
-- ============================================================================
-- Creates test users for automated e2e testing.
-- Run: supabase db reset (applies migrations + this seed)
--
-- Test Users:
--   User A: e2e-user-a@test.local / TestPass123!  (11111111-...)
--   User B: e2e-user-b@test.local / TestPass123!  (22222222-...)
-- ============================================================================

DO $$
DECLARE
  user_a_id UUID := '11111111-1111-1111-1111-111111111111';
  user_b_id UUID := '22222222-2222-2222-2222-222222222222';
  user_a_email TEXT := 'e2e-user-a@test.local';
  user_b_email TEXT := 'e2e-user-b@test.local';
  encrypted_pw TEXT := crypt('TestPass123!', gen_salt('bf'));
BEGIN
  -- ========================================
  -- USER A
  -- ========================================
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, recovery_token
  ) VALUES (
    user_a_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    user_a_email,
    encrypted_pw,
    NOW(),
    '{"provider":"email","providers":["email"]}',
    '{}',
    NOW(),
    NOW(),
    '', '', '', ''
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(),
    user_a_id,
    user_a_id::text,
    jsonb_build_object('sub', user_a_id::text, 'email', user_a_email),
    'email',
    NOW(), NOW(), NOW()
  ) ON CONFLICT ON CONSTRAINT identities_pkey DO NOTHING;

  INSERT INTO public.profiles (id, email, display_name, avatar_url, timezone)
  VALUES (
    user_a_id,
    user_a_email,
    'Test User A',
    'https://api.dicebear.com/7.x/bottts/svg?seed=e2e-user-a',
    'UTC'
  ) ON CONFLICT (id) DO NOTHING;

  -- ========================================
  -- USER B
  -- ========================================
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, recovery_token
  ) VALUES (
    user_b_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    user_b_email,
    encrypted_pw,
    NOW(),
    '{"provider":"email","providers":["email"]}',
    '{}',
    NOW(),
    NOW(),
    '', '', '', ''
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(),
    user_b_id,
    user_b_id::text,
    jsonb_build_object('sub', user_b_id::text, 'email', user_b_email),
    'email',
    NOW(), NOW(), NOW()
  ) ON CONFLICT ON CONSTRAINT identities_pkey DO NOTHING;

  INSERT INTO public.profiles (id, email, display_name, avatar_url, timezone)
  VALUES (
    user_b_id,
    user_b_email,
    'Test User B',
    'https://api.dicebear.com/7.x/bottts/svg?seed=e2e-user-b',
    'UTC'
  ) ON CONFLICT (id) DO NOTHING;
END $$;
