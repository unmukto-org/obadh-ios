# iOS emoticon prefix index

`emoticons.json` is the canonical engine **0.9.5** input: 322 case-sensitive
ASCII aliases for 29 emoji groups, based on MIT-licensed `wooorm/emoticon`
4.1.0, upstream commit `5b43e4c3e6fe43601790cc888a5e655fa9c1ffc4`.
The source SHA256 is
`8546c38c73d9020c6e2154a9b21ee722bc5eb013c4957c0784a3b53ff7ccfec3`.

Run `python3 Tools/Emoticons/generate_swift.py` from the repository to regenerate
`Shared/Sources/Engine/EmoticonRules.swift`. The tiny in-memory prefix index lets
iOS keep punctuation and letter faces intact across keyboard pages. The
real-engine integration test checks every generated mapping against source 11
from the linked engine; a release cannot silently drift from this table.

Eligible prose fields show the emoji first and the quoted typed alias second.
Space, Return and sentence punctuation choose the emoji. Tapping the literal
keeps it. A letter or operator extending a token commits the literal instead;
there is no substring, fuzzy or case-insensitive replacement. Conversion starts
only at a visible whitespace/start-of-field boundary. Email, URL, numeric,
identifier, private, secure, name and correction-disabled fields do not convert.
Withheld nonempty context also prevents starting conversion.

An immediate character Backspace after a space/punctuation replacement restores
the alias and removes its delimiter. Undo checks the exact inserted suffix and
surrounding context, and expires on another text key, focus change, cursor move
or host edit. A restored alias is not automatically converted again on Space.
Emoji and literal faces bypass personal word learning. Bangla word-to-emoji
suggestions continue to require an explicit tap.

Bangla digit keys may finish an ASCII face (`<৩` → `<3` → ❤️), but a Bangla
numeral starting a token stays numeric. Ordinary smart quotes are preserved
while an apostrophe prefix is being disambiguated. Bangla bisarga (`du:kho`)
continues through the normal phonetic composer.

The source license is retained here and distributed in
`Resources/ObadhModels/emoticons/LICENSE.txt` with the keyboard assets.
