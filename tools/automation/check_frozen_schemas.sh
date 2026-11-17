#!/usr/bin/env bash
# Une version de schéma décrit ce qui est déjà écrit sur le disque des utilisateurs. Y référencer
# un type courant fait suivre à cette version passée chaque évolution future : une valeur renommée
# aujourd'hui rend illisible demain une base écrite l'an dernier. Le gel ne coûte rien tant qu'il
# tient ; ce contrôle échoue dès qu'il se défait, plutôt qu'à la première migration cassée.
#
# Deux contrôles : (1) aucun symbole du présent dans une copie figée (liste noire ci-dessous, qui ne
# voit que ce qu'on a pensé à y mettre) ; (2) l'empreinte SHA-256 de chaque fichier figé est épinglée,
# donc toute modification, même d'une propriété, fait échouer le script.
#
# Changement de schéma voulu : ne jamais éditer un fichier figé. Créer V7 = figer V6 dans un nouveau
# `HistoricalSchemaV6.swift` (copie des modèles V6, énumérations recopiées dans `Frozen`), l'ajouter à
# FILES, puis `tools/automation/check_frozen_schemas.sh --print` et coller sa ligne dans PINNED.
# Le test `PeculeSchemaFreezeTests` épingle de son côté les propriétés de V6 (à mettre à jour avec V7).
# Retouche sans effet sur le schéma d'un fichier figé (commentaire) : même `--print`, et dire pourquoi.
set -euo pipefail

cd "$(dirname "$0")/../.."

FILES=(Pecule/Services/HistoricalSchemas.swift Pecule/Services/HistoricalSchemaV3.swift Pecule/Services/HistoricalSchemaV4.swift Pecule/Services/HistoricalSchemaV5.swift)

# Empreintes SHA-256 des fichiers figés (sortie de `--print`).
PINNED='
64a1d2f4121ef70b7d1751f1f95757384434427e5b8ec4b4415d52135b7aa117  Pecule/Services/HistoricalSchemas.swift
b48c1d932fa6b6d4b5f2dae8bdec21c211b3816a2721be389b95584f2f54a11b  Pecule/Services/HistoricalSchemaV3.swift
234b9888178daf75cccb8ced26b12a9fefe607fcaea8ff24e15a13c563423bc5  Pecule/Services/HistoricalSchemaV4.swift
acadf295a5c58e53d470dcb6e0fc3b102b51c619e29a886c8b9407dcd1b136ef  Pecule/Services/HistoricalSchemaV5.swift
'

digest() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

if [[ "${1:-}" == "--print" ]]; then
  for file in "${FILES[@]}"; do printf '%s  %s\n' "$(digest "$file")" "$file"; done
  exit 0
fi

# Symboles qui n'existent qu'au présent : aucune copie figée ne doit passer par eux.
# Les appels aux aides figées sont préfixés `Frozen.`, retiré avant l'examen.
FORBIDDEN=(
  'ExpenseCategory'
  '\.peculeMonthStart\('
  '\.currencyRounded'
  'BankTransactionCategorizer'
  'InstallmentService'
  'AppLocalizer'
  'PeculeSchema\.current'
)

status=0
for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "✗ fichier de schéma introuvable : $file"
    status=1
    continue
  fi
  pinned=$(printf '%s\n' "$PINNED" | awk -v f="$file" '$2 == f {print $1}')
  if [[ -z "$pinned" ]]; then
    echo "✗ $file n'a pas d'empreinte épinglée : ajouter sa ligne (--print) à PINNED"
    status=1
  elif [[ "$(digest "$file")" != "$pinned" ]]; then
    echo "✗ $file a changé depuis son gel (empreinte épinglée $pinned)."
    echo "    Un schéma figé décrit des bases déjà écrites : ne pas le modifier. Pour faire évoluer le schéma,"
    echo "    créer V7 (figer V6 dans HistoricalSchemaV6.swift, l'ajouter à FILES et à PINNED, --print)."
    status=1
  fi
  stripped=$(sed 's/Frozen\.//g' "$file")
  for symbol in "${FORBIDDEN[@]}"; do
    if matches=$(printf '%s\n' "$stripped" | grep -nE -- "$symbol"); then
      echo "✗ $file référence un type courant ($symbol) :"
      printf '%s\n' "$matches" | sed 's/^/    /'
      status=1
    fi
  done
done

if [[ $status -eq 0 ]]; then
  echo "✓ les schémas historiques sont intacts et ne dépendent d'aucun type courant"
fi
exit $status
