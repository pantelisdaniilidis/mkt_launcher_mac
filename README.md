# MKT Launcher

macOS αντικαταστάτης του KoalaTerm (`mkt.exe`) για telnet συνδέσεις σε VT220 εφαρμογές.

- Ενσωματωμένο VT220 terminal (SwiftTerm) με δικό του telnet, δεν χρειάζεται Terminal.app ή `telnet`.
- Λίστα συνδέσεων με προσθήκη, επεξεργασία, διπλότυπο και διαγραφή. Αποθηκεύεται στο `~/Library/Application Support/MKTLauncher/connections.json`.
- **Import .mkt…**: διαβάζει τα αρχεία του KoalaTerm (host, port, μέγεθος, Backspace, ⌃U). Με διπλό κλικ σε `.mkt` στο Finder συνδέεται αμέσως.
- Ελληνικά: ISO-8859-7 (προεπιλογή), Windows-1253, CP737, UTF-8 κ.ά., ανά σύνδεση.
- Προαιρετικό auto-login user, όπως το login script του KoalaTerm. Το password δεν αποθηκεύεται.
- Όταν μεγαλώνεις το παράθυρο ή μπαίνεις σε full screen, μεγαλώνει το κείμενο. Η οθόνη μένει πάντα 80x25.

## Πλήκτρα

**F1–F12 χωρίς fn.** Όσο το app είναι μπροστά, τα F-πλήκτρα δουλεύουν ως κανονικά F-πλήκτρα. Όταν πας σε άλλο app,
επανέρχεται η ρύθμιση του συστήματος. Το απενεργοποιείς από το Session → F1–F12 Without fn.

**Κανόνας: ⌘ στο Mac = Ctrl στα Windows.**

| Πλήκτρο | Στέλνει / κάνει |
|---|---|
| ⌘Z, ⌘A, ⌘X, … | Ctrl-Z, Ctrl-A, Ctrl-X, … στον host |
| ⌘V | Paste (οι αλλαγές γραμμής γίνονται Enter, τα ελληνικά στο charset της σύνδεσης) |
| ⌘C | Copy αν έχεις επιλέξει κείμενο, αλλιώς Ctrl-C |
| ⌘Q ⌘W ⌘H ⌘M | Τα κανονικά του Mac (έξοδος, κλείσιμο, απόκρυψη, ελαχιστοποίηση) |
| ⇧⌘R / ⇧⌘D | Επανασύνδεση / αποσύνδεση |
| Ctrl-… | Δουλεύει κανονικά όπως πριν |

Ο κανόνας ⌘ = Ctrl απενεργοποιείται από το Session → ⌘ Acts as Ctrl.

**Macros** ανά σύνδεση (Edit → Keys & macros), με τη σύνταξη του KoalaTerm:
`<ESC>` `<CR>` `<LF>` `<TAB>` `<UP>` `<DOWN>` `<LEFT>` `<RIGHT>`, `^C`, `\x1B`. Αν το αφήσεις κενό, το πλήκτρο απενεργοποιείται.
Οι προεπιλογές είναι αυτές των αρχικών .mkt:
- F5 → `ESC[16~`
- ⇧F1…⇧F10 → VT220 F11…F20
- ⇧Tab → ↑
- ⌃S απενεργοποιημένο

## Build

```sh
cp Config/connections.example.json Config/connections.json   # και βάλε τους πραγματικούς hosts
./build.sh            # universal (Apple Silicon + Intel) -> build/MKT Launcher.app
./build.sh --arm-only # μόνο Apple Silicon, πιο γρήγορο
```

Το `Config/connections.json` είναι η λίστα που βλέπει κάποιος την πρώτη φορά που ανοίγει το app. Μπαίνει μέσα στο app κατά το build
και **δεν** ανεβαίνει στο git, γιατί έχει τους εσωτερικούς hosts.

Χρειάζεται μόνο τα Command Line Tools (`xcode-select --install`). Το script κατεβάζει το SwiftTerm και καλεί απευθείας το `swiftc`.
Με πλήρες Xcode ανοίγει και το `Package.swift`.

## Εγκατάσταση σε άλλο Mac

Αντέγραψε το `MKT Launcher.app` στο `/Applications`. Είναι ad-hoc signed (όχι notarized), οπότε την πρώτη φορά:
δεξί κλικ → **Open**, ή
`xattr -dr com.apple.quarantine "/Applications/MKT Launcher.app"`.
