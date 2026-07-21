# brightglow.co — DNS records backup

Captured from Namecheap Advanced DNS on 2026-07-14, immediately before moving
DNS to Cloudflare (nameserver switch). If mail or LeadBridge sending ever
breaks after a DNS change, recreate these records exactly.

All records: **DNS only** (grey cloud) if hosted on Cloudflare — never proxied.

## Mailbox — hello@brightglow.co (Namecheap Private Email)

| Type | Host | Value | Priority/TTL |
|---|---|---|---|
| MX | `@` | `mx1.privateemail.com` | 10 |
| MX | `@` | `mx2.privateemail.com` | 10 |
| TXT | `_dmarc` | `v=DMARC1; p=none;` | |
| TXT | `privateemail._domainkey` | see DKIM value below | 30 min |

DKIM value (one string, no line breaks):

```
v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArm/G+OwQqlWSH0zirfjc9Oqf4aUbFk8UMu8LNWiphMnV/nc0XTPhJjI9Gi86Gwmvgj4D71bWo4UgHO9yTntajM8dVjxoaD+wT9foT8p2+zNXUb90Wl7yAdGJKNDK6wA5bQt7Y529IpaVGXHfHf+uF/vRIQZ/1774TWhYJKeVbWOVEu11VENYjo5wF1R/GwR5dKQiU+LKrMRcmUaghM53nLVEdVnAMZNEzJwYBs31DjzK5R5YTAMpZOe14KcNTvPcwZzb5/YBeFhj4bgV7IX3Yd45xpKQAMaF8221u0MHKRzhLtpzWJiY1fLc46sHz0cHzBBWUEB9N6dduOr08oxstQIDAQAB
```

Known gap (pre-existing): no SPF TXT record on `@`. After the Cloudflare move,
add: TXT `@` → `v=spf1 include:spf.privateemail.com ~all`

## LeadBridge sending — relay.brightglow.co (SendGrid)

| Type | Host | Value | Priority/TTL |
|---|---|---|---|
| MX | `relay` | `mx.sendgrid.net` | 10 |
| CNAME | `em5907.relay` | `u110236997.wl248.sendgrid.net` | |
| CNAME | `s1._domainkey.relay` | `s1.domainkey.u110236997.wl248.sendgrid.net` | |
| CNAME | `s2._domainkey.relay` | `s2.domainkey.u110236997.wl248.sendgrid.net` | |
| TXT | `_dmarc.relay` | `v=DMARC1; p=none;` | |

(`s1`/`s2` host names were display-truncated in Namecheap; if they turn out to
differ, the SendGrid dashboard → Settings → Sender Authentication shows the
authoritative values.)

## Not DNS, but related

- Mail settings mode in Namecheap was **Custom MX**.
- DNSSEC: off. Dynamic DNS: off.
- Site hosting (added after this backup): Cloudflare Pages project
  `brightglow`, custom domains `brightglow.co` + `www.brightglow.co` —
  Cloudflare manages those records itself.
