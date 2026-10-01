# Whisp design changes

This branch updates the native macOS app. The HTML gallery contains exported native views with test data, not a web replacement for Whisp.

## Try the app

Build and install with `bash scripts/build-app.sh --install`. Open Whisp's menu and choose **Open Setup…** to replay onboarding without resetting permissions, the cached model, history, or pill position.

1. Welcome explains the actual shortcut workflow.
2. Choose whether to keep audio recordings on this Mac. This controls the existing recording archive preference. Text history remains local in either choice.
3. Enable Microphone, Accessibility, and Input Monitoring. Each button uses the existing macOS request or Settings pane. Next stays disabled until all three permissions are available.
4. Wait for the speech model to be ready. Downloading and failure block Next. **Try again** retries a failed load.
5. Choose **Test microphone**, speak, then confirm that the purple meter moves. Dictation is paused during this check. Test audio is discarded without transcription, pasting, or history. Leaving the screen, closing setup, or losing microphone permission stops the check. It also stops after 30 seconds. **Change microphone** opens Sound settings; select your input there, return, and test again.
6. Click the reply field to type or dictate a message. The instructions use your currently configured key.
7. Click the email editor, hold your key, speak a sentence, and release. The latest dictation must appear in that editor before Next is available. Typing alone does not complete practice.
8. Optionally enable launch at login and finish setup. Closing setup early does not mark it complete.

The pill is nearly black and defaults to 135 by 38 points. Recording shows the active app icon and plain white bars. A light gray lock appears only after double-tapping into hands-free recording. Finishing or cancelling clears the lock. Processing shows a thin gray spinner with the app icon. Idle visibility and saved drag position remain intact.

Check hold/release, double-tap/tap, Escape cancellation, switching apps, the menu's pill sizes, dragging, and relaunching. Existing focus safeguards still copy text instead of pasting into a different app if you switch apps while processing.

## Automated checks

```sh
swift run -c release whisp-tests
bash scripts/build-app.sh
dist/Whisp.app/Contents/MacOS/Whisp --render-designs /tmp/whisp-design-previews
```

The test runner covers the dictation pipeline, hands-free lock reset, saved setup completion, and pill position. The preview command checks setup progression, microphone capture lifecycle with a fake recorder, lock/spinner visibility, and native editor typing, selection replacement, paste routing, and binding updates using a private test pasteboard. No desktop key events are posted. It exports thirteen onboarding scenarios and four pill states.

Real clipboard and synthetic Command-V tests remain opt-in. These checks do not prove live microphone capture, desktop text insertion, or first-run permission prompts. The owner performs that walkthrough. Test first-run permission prompts in a separate macOS user account rather than clearing existing privacy grants or the cached model.

The design follows the supplied Willow screenshots' spacing, white surfaces, lavender accents, and compact black pill. Illustrations and the icon are Whisp's own native views. It includes Whisp's real permissions and privacy controls; it does not copy testimonials or make encryption claims.
