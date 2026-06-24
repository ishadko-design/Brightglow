# Brightglow design tokens

`design/tokens.json` is the **single source of truth** for colors, spacing, radius,
sizing, and typography. It is shared three ways:

```
   Figma Variables / Text Styles                tokens.json (git)              Xcode
   ───────────────────────────────              ─────────────────              ─────
   edit visually in Figma                       source of truth                Colors.swift
        │                                              │                       Typography.swift
        │  Tokens Studio: "Import variables"           │  npm run tokens               ▲
        │  (+ "Import styles" for typography)          │  (also runs in CI)            │
        ▼                                              ▼                               │
   Tokens Studio plugin  ── Push ⬆️ / Pull ⬇️ ──►  design/tokens.json ──► DesignTokens.generated.swift
```

## Editing tokens (free workflow — edit in Figma)

The free Tokens Studio plugin can read/apply/export tokens but **cannot author
them** (creating sets / editing / deleting is gated behind Starter Plus). So we
edit tokens as **native Figma Variables**, which are free and fully editable.

1. **Edit** values in Figma's **Local variables** panel (and **Text styles** for type).
2. In Tokens Studio: **Styles & Variables → Import variables** (and **Import styles**
   for typography) to pull the changes into the `global` token set.
3. **Push** ⬆️ in Tokens Studio → updates `design/tokens.json` on `main`.
4. CI (`.github/workflows/sync-tokens.yml`) regenerates the Swift and commits it.
   On the app side just `git pull`.

To seed the Figma Variables the first time: Tokens Studio → **Styles & Variables
→ Export styles & variables to Figma → Options → enable Create variables → Export**.

## Editing tokens via git (also fine)

Edit `design/tokens.json` directly, then `npm run tokens` to regenerate the Swift.
In Figma, **Pull** ⬇️ in Tokens Studio to see the change, then re-**Export** to refresh
Variables/Styles.

## Regenerating the Swift

```sh
npm run tokens   # reads design/tokens.json → Brightglow/Theme/DesignTokens.generated.swift
```

`DesignTokens.generated.swift` is auto-generated — never edit it by hand.
`Colors.swift` / `Typography.swift` consume it (and keep app-specific extras).

## Tokens Studio sync settings

- Repository: `ishadko-design/Brightglow`
- Branch: `main`
- Token storage location: `design/tokens.json`  (repo-relative — NOT an absolute path)
- PAT: classic token with `repo` scope
