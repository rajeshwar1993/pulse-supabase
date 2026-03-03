-- Wisdom phrases table
-- Stores motivational phrases shown during pulse overlay and on the Flutter splash screen.
-- Seeded in migration (not seed.sql) since these are production content data.

CREATE TABLE public.wisdom_phrases (
    id SERIAL PRIMARY KEY,
    phrase TEXT NOT NULL,
    locale TEXT NOT NULL DEFAULT 'en',
    category TEXT NOT NULL DEFAULT 'general',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.wisdom_phrases ENABLE ROW LEVEL SECURITY;

CREATE POLICY wisdom_phrases_select_authenticated
    ON public.wisdom_phrases FOR SELECT
    TO authenticated USING (true);

CREATE INDEX idx_wisdom_phrases_locale ON public.wisdom_phrases(locale);
CREATE INDEX idx_wisdom_phrases_category ON public.wisdom_phrases(category);

INSERT INTO public.wisdom_phrases (phrase, locale, category) VALUES
    ('A simple pulse is the highlight of a parent''s morning.', 'en', 'general'),
    ('Small gestures, big impact.', 'en', 'general'),
    ('You just made someone''s day a little brighter.', 'en', 'general'),
    ('Connection doesn''t require words, just presence.', 'en', 'general'),
    ('Your check-in is their peace of mind.', 'en', 'general'),
    ('Consistency builds trust, one pulse at a time.', 'en', 'general'),
    ('You''re building a habit of care.', 'en', 'general'),
    ('Distance doesn''t matter when hearts stay connected.', 'en', 'general'),
    ('Your loved ones are smiling right now.', 'en', 'general'),
    ('This small act speaks volumes.', 'en', 'general'),
    ('Every pulse strengthens the bond.', 'en', 'general'),
    ('You''re weaving a safety net of connection.', 'en', 'general'),
    ('Regular check-ins create lasting relationships.', 'en', 'general'),
    ('Your presence matters more than you know.', 'en', 'general'),
    ('Family feels closer when you stay in touch.', 'en', 'general'),
    ('A moment of connection can change someone''s entire day.', 'en', 'general'),
    ('You''re nurturing relationships that matter.', 'en', 'general'),
    ('Love grows with consistent care.', 'en', 'general'),
    ('Your attention is a gift they treasure.', 'en', 'general'),
    ('Building bridges, one pulse at a time.', 'en', 'general'),
    ('Well done! Your consistency is remarkable.', 'en', 'general'),
    ('You''re doing great at staying connected.', 'en', 'general'),
    ('Another day of being there for the ones who matter.', 'en', 'general'),
    ('Your dedication to connection is inspiring.', 'en', 'general'),
    ('Keep going - you''re making a real difference.', 'en', 'general'),
    ('This is what showing up looks like.', 'en', 'general'),
    ('You''re creating a legacy of care.', 'en', 'general'),
    ('Your commitment to family is beautiful.', 'en', 'general'),
    ('Every pulse counts, and you''re counting on yourself.', 'en', 'general'),
    ('You''re proving that distance is just a number.', 'en', 'general'),
    ('Someone is grateful you exist right now.', 'en', 'general'),
    ('Your pulse just brought warmth to someone''s heart.', 'en', 'general'),
    ('Peace of mind delivered in an instant.', 'en', 'general'),
    ('You''re their reminder that they''re not alone.', 'en', 'general'),
    ('Anxiety replaced with assurance - that''s your gift.', 'en', 'general'),
    ('You turned someone''s worry into relief.', 'en', 'general'),
    ('Your check-in is their comfort.', 'en', 'general'),
    ('Love isn''t always loud - sometimes it''s just a pulse.', 'en', 'general'),
    ('You''re the reason someone feels secure today.', 'en', 'general'),
    ('Connection is the antidote to loneliness, and you just shared it.', 'en', 'general'),
    ('Habits like these shape who we become.', 'en', 'general'),
    ('One more day of showing up. That''s powerful.', 'en', 'general'),
    ('Routines of care create extraordinary relationships.', 'en', 'general'),
    ('You''re building a streak of kindness.', 'en', 'general'),
    ('Daily actions compound into lifelong bonds.', 'en', 'general'),
    ('Small habits, profound impact.', 'en', 'general'),
    ('Consistency is the secret ingredient of love.', 'en', 'general'),
    ('You''re making caring a daily practice.', 'en', 'general'),
    ('This routine is your relationship superpower.', 'en', 'general'),
    ('Building connection, one day at a time.', 'en', 'general'),
    ('The best investments are in people you love.', 'en', 'general'),
    ('Time spent connecting is never wasted.', 'en', 'general'),
    ('In a busy world, your pause to connect matters.', 'en', 'general'),
    ('Technology brings us together when we choose to use it well.', 'en', 'general'),
    ('Modern problems, timeless solutions: just stay in touch.', 'en', 'general'),
    ('You''re using tech to strengthen what matters most - relationships.', 'en', 'general'),
    ('The future is built on connections we nurture today.', 'en', 'general'),
    ('Your pulse is proof that you care.', 'en', 'general'),
    ('Distance is temporary, connection is forever.', 'en', 'general'),
    ('You''re redefining what it means to be present.', 'en', 'general');
