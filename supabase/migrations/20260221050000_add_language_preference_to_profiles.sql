-- Add language_preference column to profiles table
ALTER TABLE profiles
  ADD COLUMN language_preference TEXT NOT NULL DEFAULT 'en';

-- Add CHECK constraint for valid ISO 639-1 locale codes (e.g., 'en', 'es', 'en-US', 'pt-BR')
ALTER TABLE profiles
  ADD CONSTRAINT profiles_language_preference_check
  CHECK (language_preference ~ '^[a-z]{2}(-[A-Z]{2})?$');
