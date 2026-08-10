#!/bin/bash
# Garantit que pinkha.xcframework correspond aux bindings Swift avant un build.
#
# ── Pourquoi ce script existe ────────────────────────────────────────────
#
# UniFFI grave un checksum d'API des deux côtés de la frontière : dans le
# `pinkha.swift` généré et dans la bibliothèque Rust compilée. Au premier
# `PinkhaApi(...)`, `uniffiEnsurePinkhaInitialized()` compare les deux et
# appelle `fatalError` s'ils divergent. Ce n'est pas une erreur rattrapable :
# l'app meurt au lancement, pour tout le monde, sans dialogue.
#
# C'est arrivé pour de vrai — Sentry APPLE-IOS-1S, six occurrences le
# 2026-08-02, sur le simulateur de dev. Le mécanisme est banal : on touche
# du Rust (ou on change de branche, ce qui remplace `pinkha.swift`), on
# relance le script de build, et rien ne reconstruit le xcframework. Le
# build Swift réussit, l'app s'installe, elle meurt à l'ouverture.
#
# La CI a déjà une garde sur la dérive des *bindings* (elle régénère et
# diffe `pinkha.swift`). Elle ne pouvait pas voir celle-ci : le xcframework
# est gitignoré et construit localement, donc il n'existe pas en CI.
#
# ── Ce que ce script détecte, et ce qu'il ne détecte pas ─────────────────
#
# Il compare des dates de modification : toute source Rust, le `.udl` ou le
# `Cargo.lock` plus récents que le binaire du xcframework déclenchent une
# reconstruction. C'est volontairement grossier — la vraie question serait
# « les checksums concordent-ils ? », mais les extraire coûte plus cher que
# de reconstruire.
#
# Conséquence assumée : quelques reconstructions inutiles (un `touch`, une
# resync iCloud qui remonte une date). Le compromis est le bon sens :
# reconstruire pour rien coûte des minutes, lancer une app condamnée coûte
# une session de débogage sur un faux symptôme.
set -euo pipefail

cd "$(dirname "$0")/../.."   # → racine du dépôt

XCF="pinkha.xcframework"
STAMP="$XCF/.pinkha-ffi-stamp"
BINDINGS="app/Packages/PinkhaFFI/Sources/PinkhaFFI/pinkha.swift"
PROFILE="${FFI_PROFILE:-debug}"   # debug par défaut : on itère, on ne publie pas

rebuild() {
    echo "→ Reconstruction du FFI ($PROFILE) : $1"

    # ORDRE IMPORTANT : bindings d'abord, xcframework ensuite.
    #
    # La fraîcheur se mesure sur le binaire du xcframework. Régénérer les
    # bindings APRÈS le rendait plus récent que lui, donc le passage
    # suivant se croyait périmé et reconstruisait — à chaque lancement,
    # indéfiniment. Le binaire doit rester l'artefact le plus récent.
    echo "→ Régénération des bindings Swift…"
    cargo build --quiet --lib
    local lib=""
    for candidate in target/debug/libpinkha.dylib target/debug/libpinkha.so; do
        [ -f "$candidate" ] && lib="$candidate" && break
    done
    if [ -z "$lib" ]; then
        echo "✗ Aucune libpinkha trouvée après cargo build." >&2
        exit 1
    fi
    cargo run --quiet --bin uniffi-bindgen -- generate \
        --library "$lib" --language swift --out-dir swift-bindings/
    mv swift-bindings/pinkha.swift "$BINDINGS"

    ./build-xcframework.sh "$PROFILE"

    # Jeton de fraîcheur, posé en DERNIER.
    #
    # Comparer les dates aux tranches du xcframework ne marche pas : la
    # reconstruction écrit les bindings ET trois binaires dans un ordre
    # qui dépend des cibles, et `find | head -1` rend une tranche
    # arbitraire, pas la plus récente. La première version se croyait
    # donc périmée à chaque lancement et reconstruisait indéfiniment.
    # Un jeton daté après coup lève toute ambiguïté.
    touch "$STAMP"
    echo "✓ FFI à jour."
}

if [ ! -d "$XCF" ]; then
    rebuild "$XCF absent"
    exit 0
fi

if [ ! -f "$STAMP" ]; then
    rebuild "aucun jeton de fraîcheur (xcframework construit avant cette garde)"
    exit 0
fi

STALE=$(find src crates -name "*.rs" -newer "$STAMP" 2>/dev/null | head -3)
[ -z "$STALE" ] && [ src/pinkha.udl -nt "$STAMP" ] && STALE="src/pinkha.udl"
[ -z "$STALE" ] && [ Cargo.lock -nt "$STAMP" ] && STALE="Cargo.lock"
# Bindings plus récents que le jeton = branche changée sans reconstruire.
# C'est le cas exact qui a produit le crash Sentry APPLE-IOS-1S.
[ -z "$STALE" ] && [ "$BINDINGS" -nt "$STAMP" ] && STALE="$BINDINGS"

if [ -n "$STALE" ]; then
    echo "⚠ FFI périmé — plus récents que le xcframework :"
    printf '    %s\n' $STALE
    rebuild "dérive détectée"
else
    echo "✓ FFI à jour (xcframework aligné sur les sources Rust)."
fi
