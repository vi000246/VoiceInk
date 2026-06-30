# Local stable code-signing (keeps macOS permissions across rebuilds)

`make local` signs ad-hoc (`CODE_SIGN_IDENTITY = -`). Ad-hoc signatures change on **every**
build, so macOS treats each rebuild as a different app and **drops Accessibility / Microphone /
Screen Recording permissions** every time — you'd have to re-grant after each deploy.

`make deploy` fixes this by signing with a **stable self-signed identity** ("VoiceInk Local").
Its certificate hash is fixed, so the app's designated requirement stays constant:

```
identifier "com.prakashjoshipax.VoiceInk" and certificate leaf = H"<fixed cert hash>"
```

macOS then recognises every rebuild as the same app and permissions persist.

## One-time: create the "VoiceInk Local" identity

If `security find-identity -v -p codesigning` does **not** list `VoiceInk Local`, recreate it:

```bash
# 1) Self-signed cert with the Code Signing EKU
cat > /tmp/codesign.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = VoiceInk Local
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/vi-key.pem -out /tmp/vi-cert.pem \
  -days 3650 -nodes -config /tmp/codesign.cnf -extensions v3

# 2) Bundle as a LEGACY p12 (macOS `security` can't read OpenSSL 3.x default PKCS12)
openssl pkcs12 -export -inkey /tmp/vi-key.pem -in /tmp/vi-cert.pem -out /tmp/vi.p12 \
  -passout pass:voiceink -name "VoiceInk Local" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

# 3) Import the key+cert (-A so codesign can use the key without prompts)
security import /tmp/vi.p12 -k ~/Library/Keychains/login.keychain-db -P voiceink -A

# 4) Trust it for code signing (user domain — no sudo; one GUI auth prompt).
#    REQUIRED: without trust, Xcode rejects the identity and silently falls back to ad-hoc.
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/vi-cert.pem

# 5) Verify — must show "1 valid identities found"
security find-identity -v -p codesigning

rm -f /tmp/vi-key.pem /tmp/vi-cert.pem /tmp/vi.p12 /tmp/codesign.cnf
```

## Deploy

```bash
make deploy        # build (signed) → quit running app → install to /Applications → launch
```

Override the install location or identity name if needed:

```bash
make deploy APP_DEST="$HOME/Applications/VoiceInk.app" SIGN_IDENTITY="VoiceInk Local"
```

## After the FIRST stable-signed deploy

The signature changes once (ad-hoc → VoiceInk Local), so reset + re-grant **one last time**:

```bash
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
open /Applications/VoiceInk.app   # grant Accessibility in System Settings
```

From then on, `make deploy` rebuilds keep the grant. (Mic / Screen Recording / Input Monitoring
likewise persist; if any were granted under the old ad-hoc build, they need this one re-grant too.)

## Gotchas

- **Untrusted cert → silent ad-hoc fallback.** If a deploy log shows `Signing Identity: "Sign to
  Run Locally"` / `--sign -`, step 4 (trust) didn't take. Re-run it; `find-identity -v` must list it.
- **`-xcconfig LocalBuild.xcconfig` forces ad-hoc.** That file hardcodes `CODE_SIGN_IDENTITY = -`
  and wins over command-line settings, so `make deploy` does **not** use it (it passes `LOCAL_BUILD`
  and the empty team directly instead).
- **Lost the key?** Recreate it (new hash) and re-grant permissions once.
