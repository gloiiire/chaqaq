#!/usr/bin/env bash
# Configure les alias git locaux du repo chaqaq.
# Usage : ./scripts/setup-aliases.sh
# Idempotent : peut être ré-exécuté pour mettre à jour les alias.

set -e

# Vérifie qu'on est bien dans un repo git.
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Erreur : à exécuter depuis la racine du repo git chaqaq."
    exit 1
fi

# Crée une nouvelle branche feature/ depuis dev (pull à jour).
git config --local alias.new-feature \
    '!f() { git checkout dev && git pull && git checkout -b feature/$1; }; f'

# Idem pour les fix/.
git config --local alias.new-fix \
    '!f() { git checkout dev && git pull && git checkout -b fix/$1; }; f'

# Promotion dev → staging (merge + push, retour à la branche précédente).
git config --local alias.promote-staging \
    '!git checkout staging && git pull && git merge dev && git push origin staging && git checkout -'

# Promotion staging → master (release).
git config --local alias.promote-master \
    '!git checkout master && git pull && git merge staging && git push origin master && git checkout -'

# Supprime les branches locales déjà mergées dans dev (sauf master/staging/dev).
# `-E` active la regex étendue : `|` = alternation, `^[[:space:]]*` matche
# l'indentation devant un nom de branche non-active.
git config --local alias.cleanup-merged \
    '!git branch --merged dev | grep -vE "^\*|^[[:space:]]*(dev|master|staging)$" | xargs -n 1 git branch -d 2>/dev/null; echo "Done."'

echo "Alias git configurés (locaux au repo) :"
git config --local --get-regexp '^alias\.' | sed 's/^alias\./  /'
echo ""
echo "Usage :"
echo "  git new-feature <nom>       # crée feature/<nom> depuis dev"
echo "  git new-fix <nom>           # crée fix/<nom> depuis dev"
echo "  git promote-staging         # merge dev → staging + push"
echo "  git promote-master          # merge staging → master + push"
echo "  git cleanup-merged          # supprime les branches mergées dans dev"
