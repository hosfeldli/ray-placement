#!/usr/bin/env python3
"""Deterministic spelling and grammar cleanup for RayPlacement.

This intentionally uses no language model. pyspellchecker supplies the word
frequency/distance engine; the rules below handle high-confidence punctuation,
agreement, and common spoken-text mistakes. Harper performs a second rule pass
in the native app.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).with_name("site-packages")))

try:
    from spellchecker import SpellChecker
except Exception:
    SpellChecker = None


COMMON = {
    "teh": "the", "thier": "their", "wierd": "weird", "whot": "what",
    "grammer": "grammar", "recieve": "receive", "seperate": "separate",
    "definately": "definitely", "occured": "occurred", "untill": "until",
    "alot": "a lot", "dscernable": "discernible", "naviattion": "navigation",
    "performace": "performance", "effciency": "efficiency", "imrpove": "improve",
    "cna": "can", "unistaller": "uninstaller", "continu": "continue",
    "speach": "speech", "highltinged": "highlighted", "highlighing": "highlighting",
}


def preserved_terms(raw):
    words = set()
    for value in re.findall(r"[A-Za-z][A-Za-z0-9_+.#'-]*", raw or ""):
        words.add(value.lower())
    return words


def spell(text, preserve):
    checker = SpellChecker(distance=1) if SpellChecker else None

    def replace(match):
        word = match.group(0)
        lower = word.lower()
        if lower in preserve or any(char.isdigit() for char in word):
            return word
        correction = COMMON.get(lower)
        if correction is None and checker and word.islower() and len(word) >= 4 and lower in checker.unknown([lower]):
            correction = checker.correction(lower)
            if correction == lower:
                correction = None
        if not correction:
            return word
        if word[:1].isupper():
            correction = correction[:1].upper() + correction[1:]
        return correction

    return re.sub(r"\b[A-Za-z][A-Za-z'-]*\b", replace, text)


def grammar(text):
    result = text
    result = re.sub(r"\b([A-Za-z]+)(?:\s+\1\b)+", r"\1", result, flags=re.I)
    result = re.sub(r"^(\s*(?:hi|hello|hey))\s*[;:]\s+", r"\1, ", result, flags=re.I)
    result = re.sub(r"\bwhere\s+(you|we|they)\s+([A-Za-z'-]+ing)\b", r"were \1 \2", result, flags=re.I)
    result = re.sub(r"\b(you|we|they)\s+is\b", r"\1 are", result, flags=re.I)
    result = re.sub(r"\b(I)\s+is\b", r"\1 am", result)
    result = re.sub(r"\b(he|she|it)\s+are\b", r"\1 is", result, flags=re.I)
    result = re.sub(r"\bu\b", "you", result, flags=re.I)
    result = re.sub(r"\b(you)\s+really\s+is\b", r"\1 really are", result, flags=re.I)
    result = re.sub(r"\breally\s+are\s+a\s+(great|good|bad|nice)\s*$", r"really are \1", result, flags=re.I)
    result = re.sub(r",\s+(about|for|to|with|from|of|in|on)(?=\s*(?:[?.!]|$))", r" \1", result, flags=re.I)
    result = re.sub(r"\b(a)\s+([aeiou][A-Za-z'-]*)", r"an \2", result, flags=re.I)
    result = re.sub(r"\b(an)\s+([bcdfghjklmnpqrstvwxyz][A-Za-z'-]*)", r"a \2", result, flags=re.I)
    result = re.sub(r"\s+([,.;:!?])", r"\1", result)
    result = re.sub(r"([,.;:!?])(?=[A-Za-z])", r"\1 ", result)
    result = re.sub(r"[ \t]{2,}", " ", result)
    result = re.sub(r"\s+,", ",", result)

    # Capitalize the first letter after sentence punctuation without disturbing
    # acronyms, URLs, code, or the remainder of the word.
    result = re.sub(
        r"(^|(?<=[.!?])\s+)([a-z])",
        lambda match: match.group(1) + match.group(2).upper(),
        result,
    )
    if re.match(r"^(?:Hi|Hello|Hey),\s+(?:what|why|where|when|who|how|which|do|does|did|are|is|can|could|would|will|should)\b", result, re.I):
        if not result.rstrip().endswith(("?", "!", ".")):
            result = result.rstrip() + "?"
    elif result and result[-1].isalnum() and len(result.split()) >= 2:
        result += "."
    return result


def main():
    payload = json.load(sys.stdin)
    source = str(payload.get("text", ""))
    preserve = preserved_terms(str(payload.get("preserve", "")))
    print(grammar(spell(source, preserve)), end="")


if __name__ == "__main__":
    main()
