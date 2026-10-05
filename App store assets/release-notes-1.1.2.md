# Brightglow 1.1.2 (build 8) — release notes

## What's New (App Store, paste as-is)
- Prices now come from a local estimate for your area, the same every time you ask for the same job.
- Smarter questions: car and motorcycle jobs now get the same cost questions as home jobs.
- Results load in one steady pass — no jumping rows or swapping photos.
- Fewer blank rows: businesses that do your kind of work show their best photos.
- The results header names your job, and the Auto/Moto switch hides when we already know your vehicle.
- A clearer "Before you call" tip, and a cleaner bottom bar.

## Review notes (App Store Connect → App Review Information)
- No new permissions. No account needed to search.
- Estimates are informational ranges, not quotes.

## Pre-archive checklist
1. `bg` (pull latest `brightglow-ios`), open Xcode, ⌘R on a real device.
2. Search a home job and a motorcycle job; confirm: list appears once, no photo swapping, Auto/Moto switch hidden after the chat, footer has no see-through band.
3. Product → Archive → Distribute App → App Store Connect (TestFlight first).
4. Server side is already live; no deploy step.
