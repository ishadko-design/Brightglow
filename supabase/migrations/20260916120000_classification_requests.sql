-- Classification request log: one row per pricing classification request.
-- Powers "what people type" analytics with per-device attribution, so test
-- devices can be excluded via analytics_excluded_devices.
-- Written by supabase/functions/pricing (service role); never by clients.
CREATE TABLE public.classification_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text,
  category text,
  cache_key text NOT NULL,
  jobs jsonb,
  vehicle text,
  vertical text,
  cache_hit boolean NOT NULL DEFAULT false
);

CREATE INDEX classification_requests_created_at_idx
  ON public.classification_requests (created_at DESC);
CREATE INDEX classification_requests_device_id_idx
  ON public.classification_requests (device_id);

-- Locked down like classification_cache: RLS on, no policies, so only the
-- service role (Edge Functions) can read/write. Clients never touch it.
ALTER TABLE public.classification_requests ENABLE ROW LEVEL SECURITY;
