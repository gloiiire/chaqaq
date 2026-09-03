#!/usr/bin/env bash
# Configure les alias git locaux du repo pinkha.
# Usage : ./scripts/setup-aliases.sh
# Idempotent : peut être ré-exécuté pour mettre à jour les alias.

set -e

# Vérifie qu'on est bien dans un repo git.
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Erreur : à exécuter depuis la racine du repo git pinkha."
    exit 1
fi

# Crée une nouvelle branche feature/ depuis dev (pull à jour).
git config --local alias.new-feature \
    '!f() { git checkout dev && git pull && git checkout -b feature/$1; }; f'

# Idem pour les fix/.
git config --local alias.new-fix \
    '!f() { git checkout dev && git pull && git checkout -b fix/$1; }; f'

# Promotion device → dev.
git config --local alias.promote-dev \
    '!git checkout dev && git pull && git merge device && git push origin dev && git checkout -'

# Promotion dev → beta-test (les testeurs invités).
git config --local alias.promote-beta \
    '!git checkout beta-test && git pull && git merge dev && git push origin beta-test && git checkout -'

# Promotion beta-test → app-store (revue Apple).
git config --local alias.promote-app-store \
    '!git checkout app-store && git pull && git merge beta-test && git push origin app-store && git checkout -'

# Supprime les branches locales déjà mergées dans device (sauf les quatre paliers).
# `-E` active la regex étendue : `|` = alternation, `^[[:space:]]*` matche
# l'indentation devant un nom de branche non-active.
git config --local alias.cleanup-merged \
    '!git branch --merged device | grep -vE "^\*|^[[:space:]]*(device|dev|beta-test|app-store)$" | xargs -n 1 git branch -d 2>/dev/null; echo "Done."'

echo "Alias git configurés (locaux au repo) :"
git config --local --get-regexp '^alias\.' | sed 's/^alias\./  /'
echo ""
echo "Usage :"
echo "  git new-feature <nom>       # crée feature/<nom> depuis dev"
echo "  git new-fix <nom>           # crée fix/<nom> depuis dev"
echo "  git promote-dev             # merge device → dev + push"
echo "  git promote-beta            # merge dev → beta-test + push"
echo "  git promote-app-store       # merge beta-test → app-store + push"
echo "  git cleanup-merged          # supprime les branches mergées dans dev"
