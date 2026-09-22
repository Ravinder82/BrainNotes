---
version: alpha
name: BrainNotes Bridge
description: A calm command-deck system for an AI crew messenger — deep teal signal on warm paper and navy ink, native iOS type, quiet elevation, one accent that only fires on action and live state.
colors:
  primary: "#0B141A"
  secondary: "#5B6B73"
  tertiary: "#008069"
  neutral: "#F6F4F0"
  accent: "#00A884"
  tertiary-ink: "#00705C"
  surface: "#FFFFFF"
  surface-sunken: "#EFEAE2"
  surface-dark: "#0B141A"
  surface-dark-raised: "#18262E"
  bubble-incoming: "#FFFFFF"
  bubble-outgoing: "#D9FDD3"
  bubble-incoming-dark: "#1B2930"
  bubble-outgoing-dark: "#0B5E4E"
  composer-field: "#FFFFFF"
  composer-field-dark: "#22333C"
  live: "#25D366"
  danger: "#C0392B"
typography:
  h1:
    fontFamily: -apple-system
    fontSize: 1.75rem
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  h2:
    fontFamily: -apple-system
    fontSize: 1.125rem
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body-lg:
    fontFamily: -apple-system
    fontSize: 1rem
    fontWeight: 400
    lineHeight: 1.45
  body-md:
    fontFamily: -apple-system
    fontSize: 0.9375rem
    fontWeight: 400
    lineHeight: 1.45
  caption:
    fontFamily: -apple-system
    fontSize: 0.75rem
    fontWeight: 500
    lineHeight: 1.4
  overline:
    fontFamily: -apple-system
    fontSize: 0.6875rem
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "0.08em"
  meta:
    fontFamily: -apple-system
    fontSize: 0.6875rem
    fontWeight: 500
    lineHeight: 1.3
rounded:
  sm: 8px
  md: 14px
  lg: 20px
  pill: 999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
components:
  captain-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.lg}"
    padding: 16px
    height: 96px
  captain-card-dark:
    backgroundColor: "{colors.surface-dark-raised}"
    textColor: "#F2F5F6"
    rounded: "{rounded.lg}"
    padding: 16px
    height: 96px
  captain-card-accent-wash:
    backgroundColor: "{colors.tertiary}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    padding: 8px
  crew-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.lg}"
    padding: 14px
    width: 180px
    height: 196px
  crew-card-dark:
    backgroundColor: "{colors.surface-dark-raised}"
    textColor: "#F2F5F6"
    rounded: "{rounded.lg}"
    padding: 14px
    width: 180px
    height: 196px
  status-pill-live:
    backgroundColor: "{colors.tertiary}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    padding: 4px 8px
  status-pill-idle:
    backgroundColor: "{colors.surface-sunken}"
    textColor: "{colors.secondary}"
    rounded: "{rounded.pill}"
    padding: 4px 8px
  section-overline:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.secondary}"
    typography: "{typography.overline}"
    rounded: "{rounded.sm}"
    padding: 4px 8px
  setup-banner:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: 12px
  setup-banner-dark:
    backgroundColor: "{colors.surface-dark-raised}"
    textColor: "#F2F5F6"
    rounded: "{rounded.md}"
    padding: 12px
  composer-field:
    backgroundColor: "{colors.composer-field}"
    textColor: "{colors.primary}"
    rounded: "{rounded.pill}"
    padding: 10px 16px
    height: 44px
  composer-field-dark:
    backgroundColor: "{colors.composer-field-dark}"
    textColor: "#F2F5F6"
    rounded: "{rounded.pill}"
    padding: 10px 16px
    height: 44px
  composer-bar:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.lg}"
    padding: 8px
  composer-bar-dark:
    backgroundColor: "{colors.surface-dark-raised}"
    textColor: "#F2F5F6"
    rounded: "{rounded.lg}"
    padding: 8px
  send-button:
    backgroundColor: "{colors.tertiary}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    size: 34px
  icon-disc:
    backgroundColor: "{colors.tertiary}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    size: 44px
  icon-disc-quiet:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.tertiary-ink}"
    rounded: "{rounded.pill}"
    size: 36px
  icon-disc-quiet-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.accent}"
    rounded: "{rounded.pill}"
    size: 36px
  bubble-incoming:
    backgroundColor: "{colors.bubble-incoming}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: 8px 12px
  bubble-incoming-dark:
    backgroundColor: "{colors.bubble-incoming-dark}"
    textColor: "#F2F5F6"
    rounded: "{rounded.md}"
    padding: 8px 12px
  bubble-outgoing:
    backgroundColor: "{colors.bubble-outgoing}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: 8px 12px
  bubble-outgoing-dark:
    backgroundColor: "{colors.bubble-outgoing-dark}"
    textColor: "#F2F5F6"
    rounded: "{rounded.md}"
    padding: 8px 12px
  date-pill:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.secondary}"
    rounded: "{rounded.pill}"
    padding: 4px 10px
  crew-manifest-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: 12px
  crew-manifest-card-dark:
    backgroundColor: "{colors.bubble-incoming-dark}"
    textColor: "#F2F5F6"
    rounded: "{rounded.md}"
    padding: 12px
  chat-header:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.lg}"
    height: 56px
    padding: 8px
  chat-header-dark:
    backgroundColor: "{colors.surface-dark-raised}"
    textColor: "#F2F5F6"
    rounded: "{rounded.lg}"
    height: 56px
    padding: 8px
  live-dot:
    backgroundColor: "{colors.live}"
    textColor: "{colors.primary}"
    size: 7px
  error-text:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.danger}"
    typography: "{typography.caption}"
  search-field:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    rounded: "{rounded.pill}"
    padding: 8px 14px
    height: 40px
  search-field-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "#F2F5F6"
    rounded: "{rounded.pill}"
    padding: 8px 14px
    height: 40px
---

## Overview

BrainNotes is a messenger where a user drives an AI crew: a Captain assembles
specialists, and every conversation happens in cards, bubbles and one composer.
The interface should feel like a **command deck** — quiet ground, precise
typography, and exactly one colour that means "action or live". It is not a
marketing surface, so there is no hero: hierarchy comes from scale, weight and
spacing, never from decoration.

"Bridge" names the posture: warm paper on light, navy hull on dark, deep teal
as the only signal colour.

## Colors

- **Primary (#0B141A):** hull ink for headlines and core text; also the dark-mode ground.
- **Tertiary (#008069):** the deep teal used whenever white text sits on teal
  (send button, prominent buttons) — it clears WCAG AA at 4.89:1, which the
  brighter accent does not.
- **Accent (#00A884):** the live signal — icon discs, presence text, live
  status, working dots. Never a large background, never behind body copy.
- **Neutral (#F6F4F0) / surface-sunken (#EFEAE2):** the warm paper ground that
  lets white cards and bubbles lift without shadows doing all the work.
- **Live (#25D366) / danger (#C0392B):** status only, never decoration.

## Typography

The system face (`-apple-system` / SF Pro) is a deliberate choice, not a
default: this is an iOS product and SF is the only face that renders natively
at every size. The lift comes from a disciplined scale instead — one tight
display size (h1, −0.02em), one card title (h2), two body sizes, and a real
overline (11px, 600, +0.08em tracking) that replaces the ad-hoc small-caps
labels currently scattered through section headers and pills. Meta text
(11px/500) owns timestamps; nothing below 11px carries meaning.

## Layout & Spacing

4/8/16/24/32 spacing ladder. Cards sit on a 16pt gutter; content inside cards
uses 14pt padding, rows inside cards 12pt. Section overlines get 24pt of air
above them and 8pt below, so grouping is read before the label is. The main
screen is an Explore surface (scan-first: Captain, then crew rail), the chat is
a Command surface (composer always reachable, bubbles optimised for reading).

## Elevation & Depth

Two-step elevation only: the ground (paper `#F6F4F0` light / hull `#0B141A`
dark) and raised cards (`#FFFFFF` light / `#18262E` dark) separated by a 1pt
hairline — `#E4E0D9` light, `#2A3942` dark — plus a soft shadow at 8% opacity
on light mode only. Dark mode never uses shadow — the hairline carries depth.
No blur, no glass: elevation is earned by borders and value, not by haze.

## Shapes

Continuous-corner family: 8pt (small chips), 14pt (rows, bubbles, banners),
20pt (cards, header, composer bar), pill (anything tappable that holds a
single line — inputs, status pills, send). Nested containers share the family
(20 outside, 14 inside) so nothing looks bolted on.

## Components

- `captain-card` is the only surface allowed the accent wash: a 44pt teal
  disc with a white helm, one title, one role line, one muted tagline. It is
  the app's single high-emphasis entry point.
- `send-button` uses `tertiary` (#008069) behind white — the accessible teal.
  Disabled state drops to 40% opacity, never to a different hue.
- `status-pill-live` is the only pill with a filled accent; idle pills stay
  sunken grey so "working" reads at a glance.
- `icon-disc` / `icon-disc-quiet` standardise every floating glyph to a tinted
  circle: 44pt for hero actions, 36pt for secondary. No bare icons on cards.
- `bubble-incoming` / `bubble-outgoing` move from 8pt to 14pt corners with a
  12/8 padding, keeping the tail as the only asymmetry.
- `composer-field` is a full pill with a hairline, floating inside a raised
  `composer-bar`, so the input reads as a card rather than a flat strip.

## Do's and Don'ts

- DO let type scale and spacing carry hierarchy; don't add boxes to fake it.
- DO use accent teal for action and live state only; don't wash cards in it.
- DO put white-on-teal text on `tertiary` (#008069); don't put it on `accent`.
- DO keep icons inside tinted discs of a standard size; don't scatter bare glyphs.
- DO use hairlines for depth in dark mode; don't use shadows or blur there.
- DON'T introduce a second accent, a gradient background, or a font below 11px.
