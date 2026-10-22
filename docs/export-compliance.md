# Export compliance (encryption)

Cozy Safe's main job is encryption: XChaCha20-Poly1305 and Argon2id, implemented in
the app (Rust core), not Apple's or Google's built-in crypto. That puts it outside the
"uses only the operating system's encryption" case. Checked 2026-10-22 before the
public beta; not legal advice, confirm with Apple's questionnaire and BIS.

## Where we stand

- `app/ios/Runner/Info.plist` has `ITSAppUsesNonExemptEncryption = false`. That suits
  an app that uses no encryption, or only the OS's. It is likely wrong for Cozy Safe.
  TestFlight internal testing works with it, so nothing is broken today, but an App
  Review or external beta should not rest on it.
- Algorithms are industry standards (IETF RFC 8439 / XChaCha20 draft, RFC 9106 Argon2),
  so Apple's "proprietary algorithm" row (CCATS needed) does not apply.

## What Apple asks

Apple's table (App Store Connect Help, "Export compliance documentation for encryption"):

| App uses | Documentation in App Store Connect |
|---|---|
| Only the encryption inside Apple's OS | none |
| An industry-standard algorithm not provided by the OS (our case) | French encryption declaration, if distributed in France |
| Proprietary algorithms | CCATS + French declaration |

France also controls "Secure Storage" apps (ANSSI). Options: file the French declaration,
or leave France out of the App Store availability until it is filed.

## United States (BIS)

Mass-market encryption software (likely ECCN 5D992.c, authorization MMKT, License
Exception ENC §740.17(b)(1)) needs an **annual self-classification report**: a CSV with
12 columns (Supplement 8 to Part 742), emailed to BIS and the ENC Encryption Request
Coordinator (addresses on bis.gov), **by 1 February** for the previous calendar year.
A year with no exports needs no report; an unchanged year can be a short statement.
First one due: 1 February 2027, covering 2026.

## Answered 2026-10-22 (App Store Connect → App Information → App Encryption Documentation)

- Algorithms: "Standard encryption algorithms instead of, or in addition to, using or
  accessing the encryption within Apple's operating system".
- Available in France: **No**.
- Apple's answer: "you don't need to upload any documents", and the app may declare no
  non-exempt encryption in Info.plist. So `ITSAppUsesNonExemptEncryption = false` stays.
- This holds only while France is left out of App Store availability (not set up yet on
  2026-10-22: when setting it up, untick France). Selling in France
  means the French declaration first, then uploading it here.

## Earlier to-do list (kept for reference)

1. App Store Connect → Cozy Safe → App Information → App Encryption Documentation:
   answer the questions once. It says which documents are needed.
2. Decide on France: file the declaration, or remove France from availability for now.
3. Then set `ITSAppUsesNonExemptEncryption = true`, and add
   `ITSEncryptionExportComplianceCode` (the key Apple gives after approving documents)
   so CI builds are not held at "Missing Compliance". Do not flip the flag before step 1:
   every build would wait for a manual answer.
4. Diary entry for January 2027: the BIS report.

Google Play has no separate form; the developer is responsible for the same rules.

Sources: Apple, "Overview of export compliance" and "Export compliance documentation for
encryption" (App Store Connect Help); BIS, "Annual Self-Classification Report".
