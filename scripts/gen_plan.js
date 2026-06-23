const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  HeadingLevel, AlignmentType, BorderStyle, WidthType, ShadingType,
  LevelFormat, ExternalHyperlink, PageNumber, Header, Footer
} = require('/Users/test/.local/lib/node_modules/docx');
const fs = require('fs');

const CONTENT_WIDTH = 9360; // US Letter, 1" margins

// ── Helpers ──────────────────────────────────────────────────────────────────

function h1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 360, after: 160 },
    children: [new TextRun({ text, font: 'Arial', size: 36, bold: true, color: '1a1a2e' })]
  });
}

function h2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 280, after: 120 },
    children: [new TextRun({ text, font: 'Arial', size: 28, bold: true, color: '2d5a8e' })]
  });
}

function h3(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    spacing: { before: 200, after: 80 },
    children: [new TextRun({ text, font: 'Arial', size: 24, bold: true, color: '444444' })]
  });
}

function body(text, opts = {}) {
  return new Paragraph({
    spacing: { before: 60, after: 80 },
    children: [new TextRun({ text, font: 'Arial', size: 22, ...opts })]
  });
}

function bullet(text, bold_prefix = null) {
  const children = [];
  if (bold_prefix) {
    children.push(new TextRun({ text: bold_prefix + ' ', font: 'Arial', size: 22, bold: true }));
    children.push(new TextRun({ text, font: 'Arial', size: 22 }));
  } else {
    children.push(new TextRun({ text, font: 'Arial', size: 22 }));
  }
  return new Paragraph({
    numbering: { reference: 'bullets', level: 0 },
    spacing: { before: 40, after: 60 },
    children
  });
}

function numbered(text, bold_prefix = null) {
  const children = [];
  if (bold_prefix) {
    children.push(new TextRun({ text: bold_prefix + ' ', font: 'Arial', size: 22, bold: true }));
    children.push(new TextRun({ text, font: 'Arial', size: 22 }));
  } else {
    children.push(new TextRun({ text, font: 'Arial', size: 22 }));
  }
  return new Paragraph({
    numbering: { reference: 'steps', level: 0 },
    spacing: { before: 60, after: 80 },
    children
  });
}

function spacer() {
  return new Paragraph({ spacing: { before: 60, after: 60 }, children: [] });
}

function divider() {
  return new Paragraph({
    spacing: { before: 120, after: 120 },
    border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'CCCCCC', space: 1 } },
    children: []
  });
}

function note(text) {
  return new Paragraph({
    spacing: { before: 80, after: 80 },
    indent: { left: 360 },
    border: { left: { style: BorderStyle.SINGLE, size: 12, color: '22c55e', space: 120 } },
    children: [
      new TextRun({ text: 'Note: ', font: 'Arial', size: 20, bold: true, color: '166534' }),
      new TextRun({ text, font: 'Arial', size: 20, color: '166534' })
    ]
  });
}

function warn(text) {
  return new Paragraph({
    spacing: { before: 80, after: 80 },
    indent: { left: 360 },
    border: { left: { style: BorderStyle.SINGLE, size: 12, color: 'eab308', space: 120 } },
    children: [
      new TextRun({ text: 'Action required: ', font: 'Arial', size: 20, bold: true, color: '854d0e' }),
      new TextRun({ text, font: 'Arial', size: 20, color: '854d0e' })
    ]
  });
}

function statusTable(rows) {
  const border = { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' };
  const borders = { top: border, bottom: border, left: border, right: border };
  const margins = { top: 100, bottom: 100, left: 160, right: 160 };

  const headerRow = new TableRow({
    tableHeader: true,
    children: [
      new TableCell({
        borders, margins,
        width: { size: 4200, type: WidthType.DXA },
        shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
        children: [new Paragraph({ children: [new TextRun({ text: 'Task', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
      }),
      new TableCell({
        borders, margins,
        width: { size: 2400, type: WidthType.DXA },
        shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
        children: [new Paragraph({ children: [new TextRun({ text: 'Who', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
      }),
      new TableCell({
        borders, margins,
        width: { size: 1560, type: WidthType.DXA },
        shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
        children: [new Paragraph({ children: [new TextRun({ text: 'Cost', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
      }),
      new TableCell({
        borders, margins,
        width: { size: 1200, type: WidthType.DXA },
        shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
        children: [new Paragraph({ children: [new TextRun({ text: 'Status', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
      }),
    ]
  });

  const dataRows = rows.map(([task, who, cost, status], i) => {
    const fillColor = i % 2 === 0 ? 'F9FAFB' : 'FFFFFF';
    const statusColor = status === 'Done' ? '166534' : status === 'In Progress' ? '854d0e' : '374151';
    const statusBg = status === 'Done' ? 'dcfce7' : status === 'In Progress' ? 'fef3c7' : 'F3F4F6';
    return new TableRow({
      children: [
        new TableCell({
          borders, margins,
          width: { size: 4200, type: WidthType.DXA },
          shading: { fill: fillColor, type: ShadingType.CLEAR },
          children: [new Paragraph({ children: [new TextRun({ text: task, font: 'Arial', size: 20 })] })]
        }),
        new TableCell({
          borders, margins,
          width: { size: 2400, type: WidthType.DXA },
          shading: { fill: fillColor, type: ShadingType.CLEAR },
          children: [new Paragraph({ children: [new TextRun({ text: who, font: 'Arial', size: 20 })] })]
        }),
        new TableCell({
          borders, margins,
          width: { size: 1560, type: WidthType.DXA },
          shading: { fill: fillColor, type: ShadingType.CLEAR },
          children: [new Paragraph({ children: [new TextRun({ text: cost, font: 'Arial', size: 20 })] })]
        }),
        new TableCell({
          borders, margins,
          width: { size: 1200, type: WidthType.DXA },
          shading: { fill: statusBg, type: ShadingType.CLEAR },
          children: [new Paragraph({ children: [new TextRun({ text: status, font: 'Arial', size: 18, bold: true, color: statusColor })] })]
        }),
      ]
    });
  });

  return new Table({
    width: { size: CONTENT_WIDTH, type: WidthType.DXA },
    columnWidths: [4200, 2400, 1560, 1200],
    rows: [headerRow, ...dataRows]
  });
}

// ── Document ─────────────────────────────────────────────────────────────────

const doc = new Document({
  numbering: {
    config: [
      {
        reference: 'bullets',
        levels: [{
          level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 600, hanging: 300 } } }
        }]
      },
      {
        reference: 'steps',
        levels: [{
          level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 600, hanging: 300 } } }
        }]
      },
    ]
  },
  styles: {
    default: { document: { run: { font: 'Arial', size: 22 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: 'Arial', size: 36, bold: true }, paragraph: { spacing: { before: 360, after: 160 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: 'Arial', size: 28, bold: true }, paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 1 } },
      { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: 'Arial', size: 24, bold: true }, paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 2 } },
    ]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 }
      }
    },
    headers: {
      default: new Header({
        children: [new Paragraph({
          border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'CCCCCC', space: 1 } },
          children: [
            new TextRun({ text: 'FIXR — Infrastructure Build Plan', font: 'Arial', size: 18, color: '888888' }),
            new TextRun({ text: '\t', font: 'Arial', size: 18 }),
            new TextRun({ text: 'Confidential', font: 'Arial', size: 18, color: 'AAAAAA' })
          ],
          tabStops: [{ type: 'right', position: 9360 }]
        })]
      })
    },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          border: { top: { style: BorderStyle.SINGLE, size: 4, color: 'CCCCCC', space: 1 } },
          children: [
            new TextRun({ text: 'Page ', font: 'Arial', size: 18, color: '888888' }),
            new TextRun({ children: [PageNumber.CURRENT], font: 'Arial', size: 18, color: '888888' }),
            new TextRun({ text: ' — igor.shadko@gmail.com', font: 'Arial', size: 18, color: 'AAAAAA' })
          ]
        })]
      })
    },
    children: [

      // ── Cover ────────────────────────────────────────────────────────────
      new Paragraph({
        spacing: { before: 2880, after: 120 },
        children: [new TextRun({ text: 'FIXR', font: 'Arial', size: 80, bold: true, color: '1a1a2e' })]
      }),
      new Paragraph({
        spacing: { before: 0, after: 80 },
        children: [new TextRun({ text: 'Infrastructure Build Plan', font: 'Arial', size: 40, color: '2d5a8e' })]
      }),
      new Paragraph({
        spacing: { before: 0, after: 480 },
        children: [new TextRun({ text: 'Step-by-step guide to production-ready auth, real data & app store launch', font: 'Arial', size: 22, color: '666666' })]
      }),
      divider(),
      new Paragraph({
        spacing: { before: 160, after: 60 },
        children: [
          new TextRun({ text: 'Author:\t', font: 'Arial', size: 22, bold: true }),
          new TextRun({ text: 'Igor Shadko', font: 'Arial', size: 22 })
        ]
      }),
      new Paragraph({
        spacing: { before: 0, after: 60 },
        children: [
          new TextRun({ text: 'Date:\t\t', font: 'Arial', size: 22, bold: true }),
          new TextRun({ text: 'June 2026', font: 'Arial', size: 22 })
        ]
      }),
      new Paragraph({
        spacing: { before: 0, after: 60 },
        children: [
          new TextRun({ text: 'Total cost:\t', font: 'Arial', size: 22, bold: true }),
          new TextRun({ text: '$99/yr Apple Developer — everything else is free to start', font: 'Arial', size: 22 })
        ]
      }),
      spacer(),

      // ── Overview table ────────────────────────────────────────────────────
      h2('At a Glance'),
      spacer(),
      statusTable([
        ['Apple Developer Account', 'You (manual)', '$99 / yr', 'To Do'],
        ['Supabase project setup', 'You (manual)', 'Free', 'To Do'],
        ['Email OTP auth', 'Claude builds', 'Free', 'To Do'],
        ['Sign in with Apple', 'Claude builds', 'Free*', 'To Do'],
        ['Google OAuth', 'Claude builds', 'Free', 'To Do'],
        ['iOS permission dialogs', 'Claude builds', 'Free', 'To Do'],
        ['Database schema', 'Claude builds', 'Free', 'To Do'],
        ['Seed real contractor data', 'Claude builds', 'Free', 'To Do'],
        ['Push notifications', 'Claude builds', 'Free**', 'To Do'],
        ['App Store submission', 'You (manual)', 'Included in $99', 'To Do'],
      ]),
      spacer(),
      body('* Requires Apple Developer account (Phase 1).   ** APNs is free; requires Apple Developer account.', { color: '888888', size: 18 }),
      spacer(),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 1
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 1 — Apple Developer Account'),
      body('Cost: $99/yr — Time: 10 min setup, up to 48 hrs approval'),
      spacer(),
      body('This is the single mandatory purchase before you can ship to TestFlight or the App Store, and before Sign in with Apple can be enabled. Do this first — approval can take up to 48 hours.'),
      spacer(),

      h3('Why you need it'),
      bullet('Sign in with Apple — Apple requires real account for the entitlement'),
      bullet('TestFlight — beta distribution to testers outside Xcode'),
      bullet('App Store — public release'),
      bullet('Push Notifications (APNs) — auth key lives in your developer account'),
      bullet('App capabilities — background fetch, location always, etc.'),
      spacer(),

      h3('Step-by-step'),
      numbered('Open developer.apple.com/enroll in Safari'),
      numbered('Sign in with your Apple ID (igor.shadko@gmail.com)'),
      numbered('Choose Individual enrollment (no D-U-N-S number needed, no business docs)'),
      numbered('Pay $99 via credit card — activates within minutes to 48 hours'),
      numbered('In Xcode → Signing & Capabilities → Team → select your new account'),
      numbered('Enable the "Sign in with Apple" capability in Xcode (+ button → Sign in with Apple)'),
      spacer(),

      warn('You must complete Phase 1 before Sign in with Apple (Phase 2) can be wired up in code. Start the enrollment now so approval does not block development.'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 2
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 2 — Supabase Backend + Auth'),
      body('Cost: Free (500 MB DB, 50k monthly active users, 1 GB storage) — $25/mo when you scale'),
      spacer(),
      body('Supabase is a hosted Postgres database with auth, storage, and realtime built in. It replaces Firebase for this project and does NOT require Google or Firebase setup. All three login methods — email OTP, Apple, Google — are handled by Supabase.'),
      spacer(),

      h2('2A — Supabase Project Setup (you do this)'),
      h3('Create the project'),
      numbered('Go to supabase.com → sign up with GitHub or email'),
      numbered('Click New Project'),
      numbered('Name it "fixr-prod"'),
      numbered('Choose region: US East (N. Virginia) or US West (Oregon) — closest to your users'),
      numbered('Set a strong database password and save it somewhere safe'),
      numbered('Click Create Project and wait ~2 minutes for provisioning'),
      spacer(),

      h3('Get your credentials'),
      numbered('In your Supabase project → Settings → API'),
      numbered('Copy the Project URL (looks like https://xxxx.supabase.co)'),
      numbered('Copy the anon public key (long JWT string)'),
      numbered('Share both with Claude — these go into the app as constants (they are safe to include in the app bundle, just not in git)'),
      spacer(),

      warn('Do not share the service_role key. Only the anon key goes in the iOS app.'),
      spacer(),

      h3('Enable auth providers in Supabase dashboard'),
      numbered('Authentication → Providers → Email → toggle ON → enable "Confirm email" → Save'),
      numbered('Authentication → Providers → Apple → toggle ON (you will need your Apple Team ID and a Services ID — Claude will walk you through this after Phase 1 is approved)'),
      numbered('Authentication → Providers → Google → toggle ON → Claude sets this up (no Firebase needed)'),
      spacer(),

      h2('2B — Email OTP Auth (Claude builds this)'),
      body('What gets built: a 6-digit one-time passcode sent to the user\'s email by Supabase. The current placeholder (any valid email = instant login) is replaced with a real two-step flow.'),
      spacer(),

      h3('New screens / changes'),
      bullet('LoginView updated — "Continue" sends OTP, does not sign in'),
      bullet('New OTPVerifyView — 6-digit code entry with 60s resend timer'),
      bullet('AuthService rewritten — uses supabase-swift SDK instead of UserDefaults'),
      bullet('Session persistence — Supabase handles token refresh automatically'),
      spacer(),

      h3('How it works for the user'),
      numbered('User types email and taps Continue'),
      numbered('Supabase sends a 6-digit code to that email (valid 5 minutes)'),
      numbered('User enters the code in the verification screen'),
      numbered('Supabase validates it and returns a session token'),
      numbered('App is unlocked — session refreshes silently in background'),
      spacer(),

      h2('2C — Sign in with Apple (Claude builds this, requires Phase 1)'),
      body('The native ASAuthorizationController flow is already partially wired. Once you have the Apple Developer account and the entitlement enabled in Xcode, Claude replaces the stub with the real Supabase exchange.'),
      spacer(),

      h3('How it works'),
      numbered('User taps Sign in with Apple'),
      numbered('iOS shows Face ID / Touch ID sheet — no form to fill in'),
      numbered('Apple returns a signed identity token'),
      numbered('App sends token to Supabase → Supabase creates or finds the user'),
      numbered('Session returned and persisted'),
      spacer(),
      note('Apple only returns the user\'s name and email on the FIRST login. Supabase stores this for you automatically.'),
      spacer(),

      h2('2D — Google OAuth (Claude builds this, no Firebase)'),
      body('Google sign-in via Supabase uses a web-based OAuth flow (ASWebAuthenticationSession) — no Firebase SDK, no GoogleService-Info.plist required.'),
      spacer(),

      h3('You set up in Google Cloud Console (10 min)'),
      numbered('Go to console.cloud.google.com → Create project "fixr"'),
      numbered('APIs & Services → OAuth consent screen → External → fill in app name and email'),
      numbered('Credentials → Create OAuth client ID → iOS → enter your Bundle ID'),
      numbered('Copy the Client ID and paste it into Supabase → Auth → Providers → Google'),
      spacer(),
      note('Claude will provide the exact Redirect URL to paste into your Google Cloud Console during setup.'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 3
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 3 — iOS Permission Dialogs'),
      body('Cost: Free — Time: Claude builds, 30 minutes'),
      spacer(),
      body('iOS requires explicit permission dialogs before accessing camera, location, and photo library. Without the correct Info.plist entries the app crashes silently on those features. Claude builds a PermissionService that requests each permission at the right moment with clear user-facing copy.'),
      spacer(),

      h3('Permissions needed'),
      new Table({
        width: { size: CONTENT_WIDTH, type: WidthType.DXA },
        columnWidths: [3200, 3360, 2800],
        rows: [
          new TableRow({
            tableHeader: true,
            children: [
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 3200, type: WidthType.DXA },
                shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: 'Permission', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
              }),
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 3360, type: WidthType.DXA },
                shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: 'Info.plist key', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
              }),
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 2800, type: WidthType.DXA },
                shading: { fill: '1a1a2e', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: 'When asked', font: 'Arial', size: 20, bold: true, color: 'FFFFFF' })] })]
              }),
            ]
          }),
          ...([
            ['Camera', 'NSCameraUsageDescription', 'On first launch of camera screen'],
            ['Location (when in use)', 'NSLocationWhenInUseUsageDescription', 'On first contractor search'],
            ['Photo Library (read)', 'NSPhotoLibraryUsageDescription', 'When uploading a job photo'],
            ['Photo Library (write)', 'NSPhotoLibraryAddUsageDescription', 'When saving a photo from app'],
          ]).map(([perm, key, when], i) => new TableRow({
            children: [
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 3200, type: WidthType.DXA },
                shading: { fill: i % 2 === 0 ? 'F9FAFB' : 'FFFFFF', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: perm, font: 'Arial', size: 20 })] })]
              }),
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 3360, type: WidthType.DXA },
                shading: { fill: i % 2 === 0 ? 'F9FAFB' : 'FFFFFF', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: key, font: 'Courier New', size: 18 })] })]
              }),
              new TableCell({
                borders: { top: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, bottom: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, left: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' }, right: { style: BorderStyle.SINGLE, size: 1, color: 'E5E7EB' } },
                margins: { top: 100, bottom: 100, left: 160, right: 160 },
                width: { size: 2800, type: WidthType.DXA },
                shading: { fill: i % 2 === 0 ? 'F9FAFB' : 'FFFFFF', type: ShadingType.CLEAR },
                children: [new Paragraph({ children: [new TextRun({ text: when, font: 'Arial', size: 20 })] })]
              }),
            ]
          }))
        ]
      }),
      spacer(),
      h3('What Claude builds'),
      bullet('PermissionService — single class that tracks grant status for all permissions'),
      bullet('Permission request called at the right moment (not on launch — Apple rejects that)'),
      bullet('Re-prompt sheet if user previously denied — links to Settings to re-enable'),
      bullet('Info.plist entries with user-friendly dialog copy'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 4
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 4 — Real Database & Live Data'),
      body('Cost: Free on Supabase free tier — Time: Claude builds, 2–3 hours'),
      spacer(),
      body('The app currently uses a static Swift array (MockData.swift) generated from a Google Places seed script. Phase 4 moves this to a live Supabase PostgreSQL database and wires all read/write paths through the supabase-swift SDK.'),
      spacer(),

      h2('4A — Database Schema'),
      body('Claude creates these tables in Supabase via SQL migrations:'),
      spacer(),
      bullet('users — id, email, name, avatar_url, created_at (linked to Supabase auth.users)'),
      bullet('contractors — id, name, categories[], city, rating, review_count, response_time, years_active, photos[], price_tiers, phone, license_number, is_verified, place_id'),
      bullet('reviews — id, contractor_id, author, author_photo_url, rating, text, relative_time'),
      bullet('quote_requests — id, contractor_id, user_id, category, description, photo_url, urgency, timing, status, created_at'),
      spacer(),
      note('Row Level Security (RLS) is enabled so users can only see their own quote_requests. Contractors are public-readable.'),
      spacer(),

      h2('4B — Data Seeding'),
      bullet('The existing mockContractors array (200+ contractors from Google Places) is inserted into the contractors table via a one-time seed script'),
      bullet('Google Places continues to be called at runtime for fresh contractor search results, which are cached in Supabase'),
      bullet('Photos are referenced by URL (Google Places CDN) — no storage cost'),
      spacer(),

      h2('4C — Swift SDK Integration'),
      bullet('supabase-swift added via Swift Package Manager (one URL, no account required)'),
      bullet('SupabaseClient singleton replaces all MockData references'),
      bullet('EstimateService, PlacesService updated to write quote_requests to DB'),
      bullet('All queries are async/await — no callbacks, no Combine'),
      bullet('Offline: last-fetched contractors cached locally with SwiftData for graceful offline mode'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 5
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 5 — Push Notifications & Analytics'),
      body('Cost: Free — Time: Claude builds, 1 hour. Do this when you have real users.'),
      spacer(),

      h2('Push Notifications (APNs)'),
      body('Apple Push Notification service is free. Supabase Edge Functions send notifications without a third-party service.'),
      spacer(),
      numbered('In Apple Developer portal → Certificates → create an APNs Auth Key (.p8 file)'),
      numbered('Upload the .p8 to Supabase → Settings → Edge Functions → APNs config'),
      numbered('Claude adds UNUserNotificationCenter request to the app'),
      numbered('Supabase Edge Function fires when a contractor updates a quote_request status'),
      spacer(),
      note('APNs works only on a real device, not the simulator. You need at least one TestFlight build to test this.'),
      spacer(),

      h2('Analytics — PostHog'),
      body('PostHog is free up to 1 million events per month, open source, and GDPR-compliant.'),
      spacer(),
      bullet('posthog-ios SPM package — 5 lines to instrument'),
      bullet('Key events: login method used, category selected, contractor swiped, quote sent'),
      bullet('No personal data tracked — anonymous user IDs only'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // PHASE 6
      // ═══════════════════════════════════════════════════════════════════════
      h1('Phase 6 — App Store Submission'),
      body('Cost: Included in $99/yr Apple Developer — Time: 1–2 weeks for review'),
      spacer(),

      h2('Before submitting'),
      bullet('All permission dialogs present and correct (Phase 3)'),
      bullet('All auth methods working (Phase 2)'),
      bullet('No mock data visible to users (Phase 4)'),
      bullet('Privacy Policy URL — required for apps with login'),
      bullet('App icon — all sizes present (already done)'),
      bullet('Screenshots — at least iPhone 6.5" and iPhone 5.5"'),
      spacer(),

      h2('Submission steps'),
      numbered('Xcode → Product → Archive'),
      numbered('Distribute App → App Store Connect → Upload'),
      numbered('In App Store Connect: fill in metadata, screenshots, age rating'),
      numbered('Submit for Review — typical wait: 24–48 hours'),
      spacer(),
      note('Use TestFlight first. Distribute to yourself and 2–3 testers before the public submission to catch any device-specific issues.'),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // COST SUMMARY
      // ═══════════════════════════════════════════════════════════════════════
      h1('Cost Summary'),
      spacer(),
      statusTable([
        ['Apple Developer Program', 'Annual', '$99 / yr', 'Required'],
        ['Supabase — free tier', '500 MB, 50k MAU', '$0', 'Free'],
        ['Supabase — Pro (when you scale)', '8 GB, unlimited MAU', '$25 / mo', 'Later'],
        ['Google Cloud (OAuth)', 'OAuth only', '$0', 'Free'],
        ['PostHog analytics', 'Up to 1M events/mo', '$0', 'Free'],
        ['APNs push notifications', 'Unlimited', '$0', 'Free'],
        ['App Store distribution', 'Included in Dev acct', '$0', 'Included'],
      ]),
      spacer(),
      new Paragraph({
        spacing: { before: 80, after: 80 },
        border: { left: { style: BorderStyle.SINGLE, size: 16, color: '4f4fdf', space: 120 } },
        indent: { left: 360 },
        children: [
          new TextRun({ text: 'Total to launch to the App Store: ', font: 'Arial', size: 24, bold: true }),
          new TextRun({ text: '$99/yr', font: 'Arial', size: 24, bold: true, color: '4f4fdf' }),
          new TextRun({ text: '. Everything else is free until you grow past 50,000 monthly active users.', font: 'Arial', size: 24 })
        ]
      }),
      divider(),

      // ═══════════════════════════════════════════════════════════════════════
      // QUICK START
      // ═══════════════════════════════════════════════════════════════════════
      h1('Quick Start — Do These Right Now'),
      spacer(),
      body('The two actions below have no dependencies and can happen in parallel today:'),
      spacer(),
      new Paragraph({
        spacing: { before: 80, after: 80 },
        border: { left: { style: BorderStyle.SINGLE, size: 16, color: '4f4fdf', space: 120 } },
        indent: { left: 360 },
        children: [
          new TextRun({ text: 'You → ', font: 'Arial', size: 22, bold: true }),
          new TextRun({ text: 'Enroll in Apple Developer Program at developer.apple.com/enroll (takes 10 min, approval up to 48 hrs)', font: 'Arial', size: 22 })
        ]
      }),
      spacer(),
      new Paragraph({
        spacing: { before: 80, after: 80 },
        border: { left: { style: BorderStyle.SINGLE, size: 16, color: '22c55e', space: 120 } },
        indent: { left: 360 },
        children: [
          new TextRun({ text: 'Claude → ', font: 'Arial', size: 22, bold: true }),
          new TextRun({ text: 'Build Phase 3 (permission dialogs) right now — zero dependencies, pure code', font: 'Arial', size: 22 })
        ]
      }),
      spacer(),
      body('After Apple approval and Supabase project creation, share the Project URL and anon key and Claude will proceed through Phases 2 and 4.'),
    ]
  }]
});

Packer.toBuffer(doc).then(buffer => {
  fs.writeFileSync('/Users/test/Desktop/FIXR_Infrastructure_Plan.docx', buffer);
  console.log('Done');
});
