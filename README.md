<div align="center">

<img src="docs/screenshots/logo.png" width="160" height="160" alt="Nugumi logo">

# Nugumi

**Ask what to say, write, reply, or click — right on your Mac.**

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

<div align="center">

<a href="https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4"><img src="https://df41nzkzrv2ws.cloudfront.net/nugumi/demo-poster.jpg" alt="Nugumi reading a foreign-language screen and helping the user decide what to click" width="100%"></a>

<a href="https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4">▶ Watch the landing-page demo</a>

</div>

## What is Nugumi?

Nugumi helps you understand, write, reply, and decide what to click in another language without leaving the Mac app you're already using.

It is built for the moments where translation alone is not enough:

- **Ask your screen:** understand foreign-language websites, forms, warnings, and buttons.
- **Before sending:** make your draft sound natural, professional, and low-risk.
- **Before replying:** understand the message and draft a reply in your voice.
- **Before reading:** translate or simplify selected text in-place.

Works in Slack, Gmail, Notion, GitHub, Telegram, PDFs, websites, code editors, and any macOS app with selectable text.

## Main feature: Ask Nugumi

Press <kbd>Control</kbd> twice and ask Nugumi about what is on your screen:

- “Where do I click?”
- “What does this warning mean?”
- “What should I fill next?”
- “Can I safely continue?”

With a vision-capable model, Nugumi reads the visible screen, explains the context, and points you to the safe next action while you stay in control.

## Other core actions

### Understand any language

<kbd>Left-click</kbd> the Nugumi button after selecting text.

Nugumi translates the selection into your native language. If the text is already in your language, it explains jargon and dense writing in plain words.

<a href="https://df41nzkzrv2ws.cloudfront.net/nugumi/translate.mp4"><img src="https://df41nzkzrv2ws.cloudfront.net/nugumi/translate-poster.jpg" alt="Nugumi translating selected text in place" width="100%"></a>

### Send with confidence

<kbd>Right-click</kbd> the Nugumi button after selecting your draft.

Write the thought in the language that feels natural to you. Nugumi turns it into clear professional English, Korean, Japanese, or the target language you work in. If your draft is already in the target language, Nugumi polishes grammar, tone, idioms, formatting, and saved snippets.

<a href="https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native.mp4"><img src="https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native-poster.jpg" alt="Nugumi polishing a selected draft into professional text" width="100%"></a>

### Reply in your voice

Select an incoming message, customer request, recruiting note, or work thread. Nugumi drafts a concise reply using your selected writing style, snippets, and dictionary terms. Edit it, then paste.

<a href="https://df41nzkzrv2ws.cloudfront.net/nugumi/reply.mp4"><img src="https://df41nzkzrv2ws.cloudfront.net/nugumi/reply-poster.jpg" alt="Nugumi generating a full reply from a selected incoming message" width="100%"></a>

### A tiny companion, not a popup factory

Nugumi appears as a small mascot next to your selection — present when you need it, invisible when you don't.

## How it works

1. **Highlight text** in any Mac app.
2. **Left-click** to understand it in your native language.
3. **Right-click** to rewrite or translate your draft into your target language.
4. **Press Control twice** to ask about what is on your screen.

No copy-paste loop. No browser tab. No fresh prompt every time.

## Models and cost

Nugumi can run with the setup you already prefer:

- **ChatGPT subscription:** sign in and use Nugumi with your ChatGPT subscription path.
- **Ollama:** run local text actions on your Mac for free with open-source models.
- **API key:** connect your own provider key if you want direct cloud model access.

Use Ollama when privacy/cost matters. Use ChatGPT or an API key when you want stronger cloud models or vision for Ask Nugumi.

## Privacy

- Text actions can run locally through [Ollama](https://ollama.com), so selected text stays on your Mac.
- Ask Nugumi captures your screen only when you ask a screen question.
- If you use a cloud or vision model, the selected text or screenshot is sent to that provider for that request.

You choose the model based on speed, quality, privacy, and cost.

## Install

1. Download `Nugumi-X.Y.Z.dmg` from the [latest release](https://github.com/ChoiVadim/nugumi/releases/latest).
2. Open the DMG and drag **Nugumi.app** to **Applications**.
3. Launch Nugumi from Applications or Spotlight.
4. Choose your model setup: ChatGPT subscription, Ollama, or API key.
5. Follow the onboarding steps for permissions.

On first launch, Nugumi asks for:

- **Accessibility:** to read the text you select in other apps.
- **Screen Recording:** to answer questions about screen areas you explicitly ask it to inspect.

Nugumi only acts on text you select or screens you ask about.

## Updates

Nugumi updates itself through Sparkle. Use **Check for Updates...** in the menu bar to install the latest release. Updates are signed end-to-end.

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon or Intel Mac.
- One model setup: ChatGPT subscription, free local Ollama, or your own API key.
- Vision-capable model for Ask Nugumi screen questions.

## FAQ

### How is this different from Google Translate or ChatGPT?

Google Translate mostly translates. ChatGPT can help, but it lives in another tab and needs a new prompt every time. Nugumi lives next to your cursor and already knows the action from your click: ask the screen, understand, rewrite, or reply.

### Which apps does Nugumi work in?

Any macOS app with selectable text: Telegram, Slack, Safari, Chrome, Notion, Notes, Mail, VS Code, PDFs in Preview, Discord, Messages, and more.

### Is Nugumi free?

Yes. Nugumi is free during early beta. With Ollama, local text actions can run for free on your Mac. You can also use a ChatGPT subscription path or your own API key for cloud models.

## License

Nugumi is available under the [PolyForm Noncommercial License 1.0.0](LICENSE): you can use, copy, and modify it for non-commercial purposes, but commercial resale or commercial use is not allowed without separate permission.

<br>

<div align="center">

Made with 🩷 in Seoul.

</div>
