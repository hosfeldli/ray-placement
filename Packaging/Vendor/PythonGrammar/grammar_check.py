#!/usr/bin/env python3
"""Small, conservative local spelling and grammar pass for Lima.

The stealth path masks high-risk tokens before this script is called. This
script still protects user terms itself because it is also used independently
by the normal writing review flow.
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
    "recieved": "received", "eror": "error", "mistke": "mistake",
    "adress": "address", "begining": "beginning", "calender": "calendar",
    "comming": "coming", "enviroment": "environment", "occassion": "occasion",
    "tomorow": "tomorrow", "writting": "writing", "seperately": "separately",
    "untill": "until", "becuase": "because", "beleive": "believe",
    "freind": "friend", "goverment": "government", "langauge": "language",
}

TOKEN_PATTERN = re.compile(r"\b[A-Za-z][A-Za-z0-9_+.#'/-]*\b")
CORRECTABLE_CAPITALIZED_WORDS = {
    word for word in COMMON
}


COMMON_TITLE_WORDS = {
    "a", "an", "and", "another", "are", "as", "at", "be", "but", "can", "could",
    "did", "do", "does", "for", "from", "hello", "hey", "hi", "how", "i", "if",
    "in", "is", "it", "my", "no", "not", "of", "on", "or", "our", "please",
    "should", "so", "some", "that", "the", "their", "there", "these", "they", "this",
    "those", "to", "was", "we", "were", "what", "when", "where", "which", "who",
    "why", "will", "with", "would", "you", "your",
}


def preserve_terms(raw):
    terms = []
    for line in (raw or "").splitlines():
        for part in line.split(","):
            value = part.strip()
            if value:
                terms.append(value)
                terms.extend(value.split())
    return {term.lower() for term in terms if term.strip()}


def protected_spans(text, preserve):
    patterns = [
        r"(?i)\b(?:https?://|ftp://|www\.)[^\s<>\"']+",
        r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        r"`[^`\n]+`|```[\s\S]*?```",
        r"(?<![A-Za-z0-9])(?:~?/|/|\./|\.\./)[^\s]+",
        r"\b(?:v?\d+(?:\.\d+){1,}[A-Za-z0-9.-]*)\b",
        r"\b[A-Z]{2,}[A-Z0-9_./:+-]*\b",
        r"\b[A-Za-z][A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*\b",
        r"\b[A-Z][a-z]{2,}\b",
    ]
    spans = []
    for index, pattern in enumerate(patterns):
        for match in re.finditer(pattern, text):
            if index == len(patterns) - 1:
                lower = match.group(0).lower()
                if lower in COMMON_TITLE_WORDS or lower in CORRECTABLE_CAPITALIZED_WORDS:
                    continue
            spans.append(match.span())
    for term in sorted(preserve, key=len, reverse=True):
        if not term:
            continue
        spans.extend(match.span() for match in re.finditer(r"(?i)(?<![A-Za-z0-9_])" + re.escape(term) + r"(?![A-Za-z0-9_])", text))
    return merge_spans(spans)


def merge_spans(spans):
    result = []
    for start, end in sorted((s for s in spans if s[1] > s[0])):
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], end))
        else:
            result.append((start, end))
    return result




def mask_protected(text, preserve):
    spans = protected_spans(text, preserve)
    replacements = {}
    output = []
    cursor = 0
    for index, (start, end) in enumerate(spans):
        token = f"LIMAPROTECTEDTOKEN{index}X"
        output.append(text[cursor:start])
        output.append(token)
        replacements[token] = text[start:end]
        cursor = end
    output.append(text[cursor:])
    return "".join(output), replacements


def restore_protected(text, replacements):
    for token, original in replacements.items():
        if text.count(token) != 1:
            return None
        text = text.replace(token, original)
    return text

def spell(text, preserve):
    checker = SpellChecker(distance=1) if SpellChecker else None
    spans = protected_spans(text, preserve)

    def protected(start, end):
        return any(start < span_end and end > span_start for span_start, span_end in spans)

    def replace(match):
        word = match.group(0)
        if protected(match.start(), match.end()):
            return word
        lower = word.lower()
        if lower in preserve or any(char.isdigit() for char in word):
            return word
        correction = COMMON.get(lower)
        # Only run the frequency dictionary on lowercase words. Capitalized
        # and mixed-case words are possible names, products, or acronyms.
        if correction is None and checker and word.islower() and len(word) >= 4:
            if lower in checker.unknown([lower]):
                candidate = checker.correction(lower)
                if candidate and candidate != lower:
                    correction = candidate
        if not correction:
            return word
        if word[:1].isupper():
            correction = correction[:1].upper() + correction[1:]
        return correction

    return TOKEN_PATTERN.sub(replace, text)


def grammar(text, stealth=False):
    result = text
    result = re.sub(r"\b([A-Za-z]+)(?:\s+\1\b)+", r"\1", result, flags=re.I)
    result = re.sub(r"^(\s*(?:hi|hello|hey))\s*[;:]\s+", r"\1, ", result, flags=re.I)
    result = re.sub(r"\bwhere\s+(you|we|they)\s+([A-Za-z'-]+ing)\b", r"were \1 \2", result, flags=re.I)
    result = re.sub(r"\b(you|we|they)\s+is\b", r"\1 are", result, flags=re.I)
    result = re.sub(r"\b(I)\s+is\b", r"\1 am", result)
    result = re.sub(r"\b(he|she|it)\s+are\b", r"\1 is", result, flags=re.I)
    result = re.sub(r"\b(this|that)\s+are\b", r"\1 is", result, flags=re.I)
    result = re.sub(r"\b(these|those)\s+is\b", r"\1 are", result, flags=re.I)
    result = re.sub(r"\b(I)\s+(?:are|were)\b", r"\1 am", result)
    result = re.sub(r"\b(you|we|they)\s+was\b", r"\1 were", result, flags=re.I)
    result = re.sub(r"\b(he|she|it)\s+were\b", r"\1 was", result, flags=re.I)
    result = re.sub(r"\b(I|you|we|they)\s+has\b", r"\1 have", result, flags=re.I)
    result = re.sub(r"\b(he|she|it)\s+have\b", r"\1 has", result, flags=re.I)
    result = re.sub(r"\b(he|she|it)\s+do\b", r"\1 does", result, flags=re.I)
    result = re.sub(r"\b(you|we|they)\s+does\b", r"\1 do", result, flags=re.I)
    result = re.sub(r"\b(i)\b", "I", result)
    result = re.sub(r"\b(could|would|should|might|must)\s+of\b", r"\1 have", result, flags=re.I)
    if not stealth:
        result = re.sub(r"\bu\b", "you", result, flags=re.I)
        result = re.sub(r"\b(you)\s+really\s+is\b", r"\1 really are", result, flags=re.I)
        result = re.sub(r"\breally\s+are\s+a\s+(great|good|bad|nice)\s*$", r"really are \1", result, flags=re.I)
    result = re.sub(r"\b(a)\s+([aeiou][A-Za-z'-]*)", r"an \2", result, flags=re.I)
    result = re.sub(r"\b(an)\s+([bcdfghjklmnpqrstvwxyz][A-Za-z'-]*)", r"a \2", result, flags=re.I)
    result = re.sub(r",\s+(about|for|to|with|from|of|in|on)(?=\s*(?:[?.!]|$))", r" \1", result, flags=re.I)
    result = re.sub(r"\s+([,.;:!?])", r"\1", result)
    result = re.sub(r"([,.;:!?])(?=[A-Za-z])", r"\1 ", result)
    if not stealth:
        result = re.sub(r"[ \t]{2,}", " ", result)
    result = re.sub(r"\s+,", ",", result)
    result = re.sub(r"(^|(?<=[.!?])\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), result)

    interrogative = r"^(?:Hi|Hello|Hey),\s+(?:what|why|where|when|who|how|which|do|does|did|are|is|can|could|would|will|should)\b"
    if re.match(interrogative, result, re.I) and not result.rstrip().endswith(("?", "!", ".")):
        result = result.rstrip() + "?"
    elif not stealth and result and result[-1].isalnum() and len(result.split()) >= 2:
        result += "."
    return result


def main():
    payload = json.load(sys.stdin)
    source = str(payload.get("text", ""))
    preserve = preserve_terms(str(payload.get("preserve", "")))
    stealth = str(payload.get("mode", "standard")).lower() == "stealth"
    masked, replacements = mask_protected(source, preserve)
    corrected = grammar(spell(masked, preserve), stealth=stealth)
    restored = restore_protected(corrected, replacements)
    print((restored if restored is not None else source), end="")


if __name__ == "__main__":
    main()
