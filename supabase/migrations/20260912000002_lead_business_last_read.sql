-- /biz inbox read receipt: when the business opens a request, stamp when they last
-- saw it so the list can clear the "new" dot for messages up to that point. Set
-- only via LeadBridge (service role) after verifying the caller is a participant
-- on the thread; the dashboard query treats an outbound message newer than this
-- stamp as unread.
alter table leads add column if not exists business_last_read_at timestamptz;
