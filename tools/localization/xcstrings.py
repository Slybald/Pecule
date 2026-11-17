#!/usr/bin/env python3
"""Seul outil autorisé pour modifier Pecule/Resources/Localizable.xcstrings.

Usage, depuis la racine du dépôt :

  python3 tools/localization/xcstrings.py check
  python3 tools/localization/xcstrings.py set <clé> --fr "…" --en "…" [--comment "…"] [--dry-run] [--force]
  python3 tools/localization/xcstrings.py delete <clé> [<clé> …]    # clés mortes, après avoir vérifié par grep
  python3 tools/localization/xcstrings.py set <clé> --fr-one "…" --fr-other "…" --en-one "…" --en-other "…"
  python3 tools/localization/xcstrings.py set <clé> --arg 1 --fr "… %#@count@ …" --en "… %#@count@ …" \\
      --fr-one "%arg compte" --fr-other "%arg comptes" --en-one "%arg account" --en-other "%arg accounts"

`check` relit le catalogue, le réécrit en mémoire et échoue (code 1) si le résultat diffère du
fichier, à l'octet près : un fichier qui ne passe pas serait réécrit en entier au prochain `set`.

`set` ajoute la clé à sa place (ordre insensible à la casse), avec `extractionState: "manual"` et les
deux langues, obligatoires pour une clé nouvelle ; pour une clé existante, il remplace les traductions
données et garde le reste de l'entrée. Il refuse d'écrire si le catalogue ne passe pas `check` ou si le
diff dépasse 300 lignes, sauf `--force`. `--dry-run` montre le diff sans écrire.

Pluriels : avec `--fr-one/--fr-other/--en-one/--en-other` seuls, la clé n'a qu'un nombre et les textes le
contiennent (« %lld compte »). Avec `--arg N` (argument numérique n° N d'une clé qui en a plusieurs), `--fr` et
`--en` portent le gabarit avec `%#@count@` et les textes de variation écrivent `%arg` à la place du nombre : c'est la
« substitution » d'Xcode. Catégories écrites : one et other (en français, one couvre 0 et 1).

Format d'Xcode reproduit : indentation de deux espaces, séparateur `"clé" : valeur` (le `json.dump`
par défaut écrit `"clé": valeur`, et l'alternance des deux a déjà fait réécrire le catalogue en entier),
caractères non ASCII écrits tels quels, `/` non échappé. Le saut de ligne final est conservé tel quel.
Bibliothèque standard uniquement. `--catalog` désigne un autre fichier (essais sur une copie).
"""

import argparse
import difflib
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = ROOT / "Pecule" / "Resources" / "Localizable.xcstrings"
MAX_DIFF_LINES = 300


def serialize(data, trailing_newline):
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    return text + "\n" if trailing_newline else text


def load(path):
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    return raw, text, json.loads(text)


def sort_key(key):
    return (key.lower(), key)


def display(path):
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def changed_lines(before, after):
    """Diff lisible et nombre de lignes touchées, en temps linéaire sur 14 000 lignes.

    Le nombre compte tout ce qui sépare le premier écart du dernier, des deux côtés : il peut
    surestimer deux retouches voisines, jamais sous-estimer une réécriture.
    """
    a, b = before.splitlines(), after.splitlines()
    shortest = min(len(a), len(b))
    start = 0
    while start < shortest and a[start] == b[start]:
        start += 1
    end = 0
    while end < shortest - start and a[-1 - end] == b[-1 - end]:
        end += 1
    count = (len(a) - end - start) + (len(b) - end - start)
    first = max(start - 2, 0)
    diff = [f"(à partir de la ligne {first + 1})"] + list(difflib.unified_diff(
        a[first:len(a) - end + 2], b[first:len(b) - end + 2], "avant", "après", n=2, lineterm=""))
    return diff, count


def cmd_check(args):
    path = args.catalog
    raw, text, data = load(path)
    expected = serialize(data, text.endswith("\n"))
    keys = list(data.get("strings", {}))
    if expected.encode("utf-8") != raw:
        diff, count = changed_lines(text, expected)
        print(f"✗ {display(path)} n'est pas au format exact d'Xcode ({count} lignes à réécrire) :", file=sys.stderr)
        for line in diff[:24]:
            print(f"  {line}", file=sys.stderr)
        return 1
    misplaced = sum(1 for a, b in zip(keys, keys[1:]) if sort_key(a) > sort_key(b))
    print(f"✓ {display(path)} : format exact d'Xcode, {len(keys)} clés")
    if misplaced:
        print(f"  attention : {misplaced} clés hors de l'ordre insensible à la casse")
    return 0


def string_unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural_localization(one, other, arg=None, pattern=None):
    variations = {"plural": {"one": string_unit(one), "other": string_unit(other)}}
    if arg is None:
        return {"variations": variations}
    return {
        **string_unit(pattern),
        "substitutions": {"count": {"argNum": arg, "formatSpecifier": "lld", "variations": variations}},
    }


def cmd_set(args):
    path = args.catalog
    raw, text, data = load(path)
    trailing_newline = text.endswith("\n")
    if serialize(data, trailing_newline).encode("utf-8") != raw and not args.force:
        print(f"✗ {display(path)} ne passe pas `check` : l'écrire maintenant le réécrirait en entier. "
              "Comprendre l'écart d'abord (--force pour passer outre).", file=sys.stderr)
        return 1
    strings = data.get("strings")
    if not isinstance(strings, dict):
        print("✗ catalogue sans objet `strings`", file=sys.stderr)
        return 1
    key = args.key
    if not key:
        print("✗ clé vide", file=sys.stderr)
        return 2
    values = {"en": args.en, "fr": args.fr}
    plurals = {}
    for lang in ("en", "fr"):
        one, other = getattr(args, f"{lang}_one"), getattr(args, f"{lang}_other")
        if (one is None) != (other is None):
            print(f"✗ --{lang}-one et --{lang}-other vont ensemble", file=sys.stderr)
            return 2
        if one is not None:
            if args.arg is not None and values[lang] is None:
                print(f"✗ --arg exige le gabarit --{lang} avec %#@count@", file=sys.stderr)
                return 2
            plurals[lang] = plural_localization(one, other, args.arg, values[lang])
            values[lang] = None

    if key in strings:
        entry = strings[key]
        localizations = entry.get("localizations", {})
        for lang, plural in plurals.items():
            localizations[lang] = plural
        for lang, value in values.items():
            if value is None:
                continue
            current = localizations.get(lang)
            if current is not None and set(current) != {"stringUnit"}:
                print(f"✗ « {key} » a des variations ou substitutions en {lang} : à modifier dans Xcode.", file=sys.stderr)
                return 1
            localizations[lang] = string_unit(value)
        entry["localizations"] = dict(sorted(localizations.items()))
        action = "mise à jour"
    else:
        if (args.fr is None and "fr" not in plurals) or (args.en is None and "en" not in plurals):
            print("✗ une clé nouvelle exige le français et l'anglais", file=sys.stderr)
            return 2
        entry = {}
        if args.comment:
            entry["comment"] = args.comment
        entry["extractionState"] = "manual"
        entry["localizations"] = {lang: plurals.get(lang) or string_unit(values[lang]) for lang in ("en", "fr")}
        items = list(strings.items())
        position = next((i for i, (existing, _) in enumerate(items) if sort_key(existing) > sort_key(key)), len(items))
        items.insert(position, (key, entry))
        data["strings"] = dict(items)
        action = "ajoutée"

    new_text = serialize(data, trailing_newline)
    if new_text == text:
        print(f"= « {key} » inchangée")
        return 0
    diff, count = changed_lines(text, new_text)
    if count > MAX_DIFF_LINES and not args.force:
        print(f"✗ diff de {count} lignes (plafond {MAX_DIFF_LINES}) : c'est une réécriture, pas une modification. "
              "Rien n'est écrit (--force pour passer outre).", file=sys.stderr)
        return 1
    if args.dry_run:
        print("\n".join(diff))
        print(f"(essai) « {key} » serait {action} : {count} lignes modifiées")
        return 0
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(new_text.encode("utf-8"))
        os.chmod(temporary, os.stat(path).st_mode & 0o7777)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise
    print(f"✓ « {key} » {action} dans {display(path)} : {count} lignes modifiées")
    return 0


def cmd_delete(args):
    path = args.catalog
    raw, text, data = load(path)
    trailing_newline = text.endswith("\n")
    if serialize(data, trailing_newline).encode("utf-8") != raw:
        print(f"✗ {display(path)} ne passe pas `check` : comprendre l'écart d'abord.", file=sys.stderr)
        return 1
    missing = [key for key in args.keys if key not in data["strings"]]
    if missing:
        print(f"✗ clés absentes : {', '.join(missing)}", file=sys.stderr)
        return 2
    for key in args.keys:
        del data["strings"][key]
    new_text = serialize(data, trailing_newline)
    _, count = changed_lines(text, new_text)
    if count > MAX_DIFF_LINES:
        print(f"✗ diff de {count} lignes (plafond {MAX_DIFF_LINES}). Rien n'est écrit.", file=sys.stderr)
        return 1
    path.write_bytes(new_text.encode("utf-8"))
    print(f"✓ {len(args.keys)} clé(s) supprimée(s) de {display(path)} : {count} lignes modifiées")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Modifie Localizable.xcstrings au format exact d'Xcode.")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG, help="catalogue à traiter (défaut : celui de l'app)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="échoue si le catalogue n'est pas au format exact d'Xcode")
    setter = commands.add_parser("set", help="ajoute ou met à jour une clé")
    setter.add_argument("key", help="clé du catalogue")
    setter.add_argument("--fr", help="texte français")
    setter.add_argument("--en", help="texte anglais")
    setter.add_argument("--fr-one", help="français, pluriel : forme « one » (0 et 1)")
    setter.add_argument("--fr-other", help="français, pluriel : forme « other »")
    setter.add_argument("--en-one", help="anglais, pluriel : forme « one »")
    setter.add_argument("--en-other", help="anglais, pluriel : forme « other »")
    setter.add_argument("--arg", type=int, help="n° de l'argument numérique quand la clé en a plusieurs (substitution)")
    setter.add_argument("--comment", help="commentaire pour les traducteurs (clé nouvelle seulement)")
    setter.add_argument("--dry-run", action="store_true", help="affiche le diff sans écrire")
    setter.add_argument("--force", action="store_true", help="écrit malgré un écart de format ou un gros diff")
    deleter = commands.add_parser("delete", help="supprime des clés (mortes) ; vérifier d'abord qu'aucun code ne les lit")
    deleter.add_argument("keys", nargs="+")
    args = parser.parse_args(argv)
    return {"check": cmd_check, "set": cmd_set, "delete": cmd_delete}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
