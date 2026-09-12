-- Track Stripe's cancel_at_period_end on the billing cache so the portal can
-- show "Cancels <date>" instead of "Renews <date>" after a business schedules
-- cancellation. Written only by the LeadBridge Stripe webhook.
ALTER TABLE business_billing
  ADD COLUMN IF NOT EXISTS cancel_at_period_end boolean NOT NULL DEFAULT false;
