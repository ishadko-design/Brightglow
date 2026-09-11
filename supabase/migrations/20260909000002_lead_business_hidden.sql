-- "Delete" a request from the business's list — a SOFT hide. The lead row and
-- the customer's side are untouched (their thread + the /l page still work); we
-- only stamp when the business dismissed it so the dashboard stops listing it.
-- Set only via LeadBridge (service role) after verifying the caller is the
-- matched business; the dashboard query filters on it.
alter table leads add column if not exists business_hidden_at timestamptz;
