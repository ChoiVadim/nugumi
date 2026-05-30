<div align="center">

<img src="docs/screenshots/logo.png" width="160" height="160" alt="Nugumi logo">

# Nugumi

**Confidence before you send, reply, or click.**

A Mac assistant for non-native professionals who work across languages.

<br>

<a href="https://github.com/ChoiVadim/nugumi/releases/latest">
  <img src="https://img.shields.io/badge/Download-Nugumi.dmg-7C3AED?style=for-the-badge&logo=apple&logoColor=white" alt="Download Nugumi" height="44">
</a>

<br><br>

<img src="https://img.shields.io/badge/macOS-14%2B-555?style=flat-square" alt="macOS 14+">
<img src="https://img.shields.io/github/v/release/ChoiVadim/nugumi?style=flat-square&color=7C3AED" alt="Latest release">
<img src="https://img.shields.io/github/downloads/ChoiVadim/nugumi/total?style=flat-square&color=4ade80" alt="Total downloads">

</div>

<br>

![Nugumi translating a message in Telegram](docs/screenshots/translate.png)

## What is Nugumi?

Nugumi helps you understand, write, and reply in another language without leaving the Mac app you're already using.

It is built for the moments where translation alone is not enough:

- **Before sending:** make your draft sound natural, professional, and low-risk.
- **Before replying:** understand the message and draft a reply in your voice.
- **Before clicking:** ask what a foreign-language screen, form, warning, or button means.

Works in Slack, Gmail, Notion, GitHub, Telegram, PDFs, websites, code editors, and any macOS app with selectable text.

## Core actions

### Understand any language

<kbd>Left-click</kbd> the Nugumi button after selecting text.

Nugumi translates the selection into your native language. If the text is already in your language, it explains jargon and dense writing in plain words.

<img src="docs/screenshots/translate.png" alt="Understand selected text" width="100%">

### Send with confidence

<kbd>Right-click</kbd> the Nugumi button after selecting your draft.

Write the thought in the language that feels natural to you. Nugumi turns it into clear professional English, Korean, Japanese, or the target language you work in. If your draft is already in the target language, Nugumi polishes grammar, tone, idioms, formatting, and saved snippets.

### Reply in your voice

Select an incoming message, customer request, recruiting note, or work thread. Nugumi drafts a concise reply using your selected writing style, snippets, and dictionary terms. Edit it, then paste.

<img src="docs/screenshots/reply.png" alt="Smart reply suggestions" width="100%">

### Ask Nugumi about your screen

Press <kbd>Control</kbd> twice and ask a question like:

- “Where do I click?”
- “What does this warning mean?”
- “What should I fill next?”

With a vision-capable model, Nugumi reads the screen and points you to the safe next action while you stay in control.

### A tiny companion, not a popup factory

Nugumi appears as a small mascot next to your selection — present when you need it, invisible when you don't.

<img src="docs/screenshots/pet.png" alt="Floating pet companion" width="100%">

## How it works

1. **Highlight text** in any Mac app.
2. **Left-click** to understand it in your native language.
3. **Right-click** to rewrite or translate your draft into your target language.
4. **Press Control twice** to ask about what is on your screen.

No copy-paste loop. No browser tab. No fresh prompt every time.

## Privacy and models

Nugumi supports both local and cloud model workflows:

- **Local text mode:** pair Nugumi with [Ollama](https://ollama.com) and run text actions on your Mac.
- **Cloud/vision mode:** use a vision-capable model for screen questions. Screenshots are captured only when you ask Nugumi a screen question.

You choose the model based on speed, quality, and privacy needs.

## Install

1. Download `Nugumi-X.Y.Z.dmg` from the [latest release](https://github.com/ChoiVadim/nugumi/releases/latest).
2. Open the DMG and drag **Nugumi.app** to **Applications**.
3. Launch Nugumi from Applications or Spotlight.
4. Follow the onboarding steps for permissions and model setup.

On first launch, Nugumi asks for:

- **Accessibility:** to read the text you select in other apps.
- **Screen Recording:** to answer questions about screen areas you explicitly ask it to inspect.

Nugumi only acts on text you select or screens you ask about.

## Updates

Nugumi updates itself through Sparkle. Use **Check for Updates...** in the menu bar to install the latest release. Updates are signed end-to-end.

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon or Intel Mac.
- [Ollama](https://ollama.com) for local text mode.
- Optional cloud model/API setup for vision-powered screen questions.

## FAQ

### How is this different from Google Translate or ChatGPT?

Google Translate mostly translates. ChatGPT can help, but it lives in another tab and needs a new prompt every time. Nugumi lives next to your cursor and already knows the action from your click: understand, rewrite, reply, or ask your screen.

### Which apps does Nugumi work in?

Any macOS app with selectable text: Telegram, Slack, Safari, Chrome, Notion, Notes, Mail, VS Code, PDFs in Preview, Discord, Messages, and more.

### Is Nugumi free?

Yes. Nugumi is free during early beta. No signup required.

## License

Nugumi is available under the [PolyForm Noncommercial License 1.0.0](LICENSE): you can use, copy, and modify it for non-commercial purposes, but commercial resale or commercial use is not allowed without separate permission.

<br>

<div align="center">

Made with 🩷 in Seoul.

</div>
