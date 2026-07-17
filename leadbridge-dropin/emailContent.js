// Drop-in for the LeadBridge repo (Node on Railway).
//
// The additions to the lead-notification email:
//   1. A response-time ETA nudge (respond fast → win the job).
//   2. A "Claim your page" CTA → the web CRM at brightglow.co/business.
//   3. A "Reply in the app" button → deep-links straight to THIS conversation.
//   4. A CAN-SPAM–compliant unsubscribe footer + the List-Unsubscribe headers.
//
// Wire these into your existing mailer where the lead email HTML is assembled.

const { unsubscribeToken } = require("./emailSuppressions");

const SITE = process.env.PUBLIC_SITE_URL || "https://brightglow.co";
// Where the unsubscribe endpoints are mounted (see unsubscribeRoute.js). Usually
// the LeadBridge public URL.
const API = process.env.PUBLIC_API_URL || "https://leadbridge-production-4065.up.railway.app";
const ACCENT = "#0039f5";

// The main content block to inject into the lead email body. `publicId` is the
// lead's public_id (the same id the app's deep link uses).
function leadEmailBlock({ publicId, city }) {
  const claimUrl = `${SITE}/business/`;
  const replyUrl = `${SITE}/chat/${encodeURIComponent(publicId)}`; // Universal Link → opens the app thread
  return `
  <div style="margin:24px 0;padding:16px 18px;background:#f4f6ff;border-radius:12px;
              border:1px solid #dbe3ff;font-size:14px;color:#1a1a1a;">
    ⏱ <b>Reply fast to win the job.</b> Customers who hear back within a day are far
    more likely to hire. ${city ? `This request is in <b>${escapeHtml(city)}</b>.` : ""}
  </div>

  <table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 4px">
    <tr><td style="border-radius:999px;background:${ACCENT}">
      <a href="${replyUrl}" style="display:inline-block;padding:13px 26px;color:#fff;
         font-weight:700;text-decoration:none;font-family:Arial,sans-serif;border-radius:999px">
        Reply in the Brightglow app →
      </a>
    </td></tr>
  </table>

  <p style="font-size:14px;color:#444;line-height:1.5;margin:16px 0 0">
    <b>This is your business.</b> Claim your page to add your services, prices, and
    photos of your work — it's what customers scroll first when they choose who to
    hire. <a href="${claimUrl}" style="color:${ACCENT};font-weight:700">Claim your page →</a>
  </p>`;
}

// Footer that MUST appear in every marketing/relationship email (physical address
// + one-click unsubscribe). Set BUSINESS_POSTAL_ADDRESS in env (CAN-SPAM requires
// a valid physical postal address).
function unsubscribeFooter(email) {
  const link = unsubscribeUrl(email);
  const addr = process.env.BUSINESS_POSTAL_ADDRESS || "Brightglow LLC";
  return `
  <hr style="border:none;border-top:1px solid #e6e6e6;margin:28px 0 14px">
  <p style="font-size:12px;color:#999;line-height:1.5;font-family:Arial,sans-serif">
    You're receiving this because a customer requested your services on Brightglow.<br>
    ${escapeHtml(addr)}<br>
    <a href="${link}" style="color:#999">Unsubscribe</a> from these notifications.
  </p>`;
}

function unsubscribeUrl(email) {
  const t = unsubscribeToken(email);
  return `${API}/api/unsubscribe?e=${encodeURIComponent(email)}&t=${t}`;
}

// Headers to add to the SendGrid/SMTP send so mail clients show a native
// "Unsubscribe" button and can one-click opt out (RFC 8058).
function unsubscribeHeaders(email) {
  const link = unsubscribeUrl(email);
  return {
    "List-Unsubscribe": `<mailto:unsubscribe@brightglow.co?subject=unsubscribe>, <${link}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

function escapeHtml(s) {
  return String(s || "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

module.exports = { leadEmailBlock, unsubscribeFooter, unsubscribeHeaders, unsubscribeUrl };
